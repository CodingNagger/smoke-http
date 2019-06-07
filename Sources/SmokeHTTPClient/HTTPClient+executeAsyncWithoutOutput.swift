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
//  HTTPClient+executeAsyncWithoutOutput.swift
//  SmokeHTTPClient
//

import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOTLS
import Logging
import Metrics

public extension HTTPClient {
    /**
     Submits a request that will not return a response body to this client asynchronously.
     The completion handler's execution will be scheduled on DispatchQueue.global()
     rather than executing on a thread from SwiftNIO.
     
     - Parameters:
     - endpointPath: The endpoint path for this request.
     - httpMethod: The http method to use for this request.
     - input: the input body data to send with this request.
     - completion: Completion handler called with an error if one occurs or nil otherwise.
     - handlerDelegate: the delegate used to customize the request's channel handler.
     */
    func executeAsyncWithoutOutput<InputType>(
        endpointOverride: URL? = nil,
        endpointPath: String,
        httpMethod: HTTPMethod,
        input: InputType,
        completion: @escaping (Error?) -> (),
        invocationContext: HTTPClientInvocationContext) throws -> EventLoopFuture<Channel>
        where InputType: HTTPRequestInputProtocol {
            return try executeAsyncWithoutOutput(
                endpointOverride: endpointOverride,
                endpointPath: endpointPath,
                httpMethod: httpMethod,
                input: input,
                completion: completion,
                asyncResponseInvocationStrategy: GlobalDispatchQueueAsyncResponseInvocationStrategy<Error?>(),
                invocationContext: invocationContext)
    }
    
    /**
     Submits a request that will not return a response body to this client asynchronously.
     
     - Parameters:
     - endpointPath: The endpoint path for this request.
     - httpMethod: The http method to use for this request.
     - input: the input body data to send with this request.
     - completion: Completion handler called with an error if one occurs or nil otherwise.
     - asyncResponseInvocationStrategy: The invocation strategy for the response from this request.
     - handlerDelegate: the delegate used to customize the request's channel handler.
     */
    func executeAsyncWithoutOutput<InputType, InvocationStrategyType>(
        endpointOverride: URL? = nil,
        endpointPath: String,
        httpMethod: HTTPMethod,
        input: InputType,
        completion: @escaping (Error?) -> (),
        asyncResponseInvocationStrategy: InvocationStrategyType,
        invocationContext: HTTPClientInvocationContext) throws -> EventLoopFuture<Channel>
        where InputType: HTTPRequestInputProtocol, InvocationStrategyType: AsyncResponseInvocationStrategy,
        InvocationStrategyType.OutputType == Error? {
            
            let durationMetricDetails: (Date, Metrics.Timer)?
            if let durationTimer = invocationContext.reporting.durationTimer {
                durationMetricDetails = (Date(), durationTimer)
            } else {
                durationMetricDetails = nil
            }
            
            var hasComplete = false
            // create a wrapping completion handler to pass to the ChannelInboundHandler
            let wrappingCompletion: (Result<HTTPResponseComponents, Swift.Error>) -> () = { (rawResult) in
                let result: Error?
                
                switch rawResult {
                case .failure(let error):
                    // its an error, complete with this error
                    result = error
                    
                    // report failure metric
                    invocationContext.reporting.failureCounter?.increment()
                case .success:
                    // its a successful completion, complete with an empty error.
                    result = nil
                    
                    // report success metric
                    invocationContext.reporting.successCounter?.increment()
                }
                
                if let durationMetricDetails = durationMetricDetails {
                    durationMetricDetails.1.recordMicroseconds(Date().timeIntervalSince(durationMetricDetails.0))
                }
                
                asyncResponseInvocationStrategy.invokeResponse(response: result, completion: completion)
                hasComplete = true
            }
            
            // submit the asynchronous request
            let channelFuture = try executeAsync(endpointOverride: endpointOverride,
                                                 endpointPath: endpointPath,
                                                 httpMethod: httpMethod,
                                                 input: input,
                                                 completion: wrappingCompletion,
                                                 invocationContext: invocationContext)
            
            channelFuture.whenComplete { result in
                switch result {
                case .success(let channel):
                    channel.closeFuture.whenComplete { _ in
                        // if this channel is being closed and no response has been recorded
                        if !hasComplete {
                            completion(HTTPClient.unexpectedClosureType)
                        }
                    }
                case .failure(let error):
                    // there was an issue creating the channel
                    completion(error)
                }
            }
            
            return channelFuture
    }
}
