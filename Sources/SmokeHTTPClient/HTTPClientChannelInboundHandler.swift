// Copyright 2018-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  HTTPClientChannelInboundHandler.swift
//  SmokeHTTPClient
//

import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOTLS
import NIOFoundationCompat
import Logging

private let logger = Logger(label: "com.amazon.SmokeHTTPClient.HTTPClientChannelInboundHandler")

internal struct HttpHeaderNames {
    /// Content-Length Header
    static let contentLength = "Content-Length"

    /// Content-Type Header
    static let contentType = "Content-Type"
}

/**
 Implementation of the ChannelInboundHandler protocol that handles sending
 data to the server and receiving a response.
 */
public final class HTTPClientChannelInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    /// The content type of the payload being sent.
    public let contentType: String
    /// The endpoint url to request a response from.
    public let endpointUrl: URL
    /// The path to request a response from.
    public let endpointPath: String
    /// The http method to use for the request.
    public let httpMethod: HTTPMethod
    /// The request body data to use.
    public let bodyData: Data
    /// Any additional headers to add
    public let additionalHeaders: [(String, String)]
    /// The http head of the response received
    public var responseHead: HTTPResponseHead?
    /// The body data previously received.
    public var partialBody: Data?

    /// A completion handler to pass any recieved response to.
    private let completion: (Result<HTTPResponseComponents, Swift.Error>) -> ()
    /// A function that provides an Error based on the payload provided.
    private let errorProvider: (HTTPResponseHead, HTTPResponseComponents) throws -> Error
    /// Delegate that provides client-specific logic
    private let delegate: HTTPClientChannelInboundHandlerDelegate

    /**
     Initializer.

     - Parameters:
     - contentType: The content type of the payload being sent.
     - endpointUrl: The endpoint url to request a response from.
     - endpointPath: The path to request a response from.
     - httpMethod: The http method to use for the request.
     - bodyData: The request body data to use.
     - additionalHeaders: any additional headers to add to the request.
     - errorProvider: A completion handler to pass any recieved response to.
     - completion: A function that provides an Error based on the payload provided.
     */
    init(contentType: String,
         endpointUrl: URL,
         endpointPath: String,
         httpMethod: HTTPMethod,
         bodyData: Data,
         additionalHeaders: [(String, String)],
         errorProvider: @escaping (HTTPResponseHead, HTTPResponseComponents) throws -> Error,
         completion: @escaping (Result<HTTPResponseComponents, Swift.Error>) -> (),
         channelInboundHandlerDelegate: HTTPClientChannelInboundHandlerDelegate) {
        self.contentType = contentType
        self.endpointUrl = endpointUrl
        self.endpointPath = endpointPath
        self.httpMethod = httpMethod
        self.bodyData = bodyData
        self.additionalHeaders = additionalHeaders
        self.errorProvider = errorProvider
        self.completion = completion
        self.delegate = channelInboundHandlerDelegate
    }

    /**
     Called when data has been received from the channel.
     */
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responsePart = self.unwrapInboundIn(data)

        switch responsePart {
        // This is the response head
        case .head(let response):
            responseHead = response
            logger.debug("Response head received.")
        // This is part of the response body
        case .body(var byteBuffer):
            let byteBufferSize = byteBuffer.readableBytes
            let newData = byteBuffer.readData(length: byteBufferSize)
            
            if var newPartialBody = partialBody,
                let newData = newData {
                    newPartialBody += newData
                    partialBody = newPartialBody
            } else if let newData = newData {
                partialBody = newData
            }
            
            logger.debug("Response body part of \(byteBufferSize) bytes received.")
        // This is the response end
        case .end:
            logger.debug("Response end received.")
            // the head and all possible body parts have been received,
            // handle this response
            handleCompleteResponse(context: context, bodyData: partialBody)
            partialBody = nil
        }
    }
    
    private func getHeadersFromResponse(header: HTTPResponseHead) -> [(String, String)] {
        let headers: [(String, String)] = header.headers.map { header in
            return (header.name, header.value)
        }
        
        return headers
    }

    /*
     Handles when the response has been completely received.
     */
    func handleCompleteResponse(context: ChannelHandlerContext, bodyData: Data?) {
        // always close the channel context after the processing in this method
        defer {
            logger.debug("Closing channel on complete response.")
            context.close(promise: nil)
            logger.debug("Channel closed on complete response.")
        }

        logger.debug("Handling response body with \(bodyData?.count ?? 0) size.")

        // ensure the response head from received
        guard let responseHead = responseHead else {
            let error = HTTPError.badResponse("Response head was not received")

            logger.error("Response head was not received")

            // complete with this error
            completion(.failure(error))
            return
        }
        
        let headers = getHeadersFromResponse(header: responseHead)
        let responseComponents = HTTPResponseComponents(headers: headers,
                                                        body: bodyData)

        let logMessagePrefix = "Got response from endpoint: \(endpointUrl) and path: \(endpointPath) with " +
                "headers: \(responseHead) and"
        if let bodyData = bodyData {
            logger.debug("\(logMessagePrefix) body: \(bodyData)")
        } else {
            logger.debug("\(logMessagePrefix) empty body.")
        }
        
        let isSuccess: Bool
        switch responseHead.status {
        case .ok, .created, .accepted, .nonAuthoritativeInformation, .noContent, .resetContent, .partialContent:
            isSuccess = true
        default:
            isSuccess = false
        }

        // if the response status is ok
        if isSuccess {
            // complete with the response data (potentially empty)
            completion(.success(responseComponents))
            return
        }

        // Handle client delegated errors
        if let error = delegate.handleErrorResponses(responseHead: responseHead, responseBodyData: bodyData) {
            completion(.failure(error))
            return
        }

        let responseError: Error
        do {
            // attempt to get the error from the provider
            responseError = try errorProvider(responseHead, responseComponents)
        } catch {
            // if the provider throws an error, use this error
            responseError = error
        }

        // complete with the error
        completion(.failure(responseError))
    }

    /**
     Called when notifying about a connection error.
     */
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("Error received from HTTP connection: \(String(describing: error))")

        // close the channel
        context.close(promise: nil)
    }

    /**
     Called when the channel becomes active.
     */
    public func channelActive(context: ChannelHandlerContext) {
        logger.debug("Preparing request on channel active.")
        var headers = delegate.addClientSpecificHeaders(handler: self)

        // TODO: Move headers out to HTTPClient for UrlRequest
        if bodyData.count > 0 || delegate.specifyContentHeadersForZeroLengthBody {
            headers.append((HttpHeaderNames.contentType, contentType))
            headers.append((HttpHeaderNames.contentLength, "\(bodyData.count)"))
        }
        headers.append(("User-Agent", "SmokeHTTPClient"))
        headers.append(("Accept", "*/*"))

        // Create the request head
        var httpRequestHead = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                              method: httpMethod, uri: endpointPath)
        httpRequestHead.headers = HTTPHeaders(headers)

        // copy the body data to a ByteBuffer
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        let array = [UInt8](bodyData)
        buffer.writeBytes(array)

        // Send the request on the channel.
        context.write(self.wrapOutboundOut(.head(httpRequestHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        logger.debug("Request prepared on channel active.")
    }
}
