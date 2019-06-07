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
//  HTTPClient+executeSyncRetriableWithoutOutput.swift
//  SmokeHTTPClient
//

import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOTLS
import Logging
import Metrics

private extension Int {
    var milliFromMicroSeconds: Int {
        return self * 1000
    }
}

public extension HTTPClient {
    /**
     Helper type that manages the state of a retriable sync request.
     */
    private class ExecuteSyncWithoutOutputRetriable<InputType>
            where InputType: HTTPRequestInputProtocol {
        let endpointOverride: URL?
        let endpointPath: String
        let httpMethod: HTTPMethod
        let input: InputType
        let invocationContext: HTTPClientInvocationContext
        let innerInvocationContext: HTTPClientInvocationContext
        let httpClient: HTTPClient
        let retryConfiguration: HTTPClientRetryConfiguration
        let retryOnError: (Swift.Error) -> Bool
        let durationMetricDetails: (Date, Metrics.Timer)?
        
        var retriesRemaining: Int
        
        init(endpointOverride: URL?, endpointPath: String, httpMethod: HTTPMethod,
             input: InputType,
             invocationContext: HTTPClientInvocationContext,
             httpClient: HTTPClient,
             retryConfiguration: HTTPClientRetryConfiguration,
             retryOnError: @escaping (Swift.Error) -> Bool) {
            self.endpointOverride = endpointOverride
            self.endpointPath = endpointPath
            self.httpMethod = httpMethod
            self.input = input
            self.invocationContext = invocationContext
            self.httpClient = httpClient
            self.retryConfiguration = retryConfiguration
            self.retriesRemaining = retryConfiguration.numRetries
            self.retryOnError = retryOnError
            
            if let durationTimer = invocationContext.reporting.durationTimer {
                self.durationMetricDetails = (Date(), durationTimer)
            } else {
                self.durationMetricDetails = nil
            }
            // When using retry wrappers, the `HTTPClient` itself should record any metrics.
            let innerReporting = HTTPClientInnerRetryInvocationReporting(logger: invocationContext.reporting.logger)
            self.innerInvocationContext = HTTPClientInvocationContext(reporting: innerReporting, handlerDelegate: invocationContext.handlerDelegate)
        }
        
        func executeSyncWithoutOutput() throws {
            defer {
                // report the retryCount metric
                let retryCount = retryConfiguration.numRetries - retriesRemaining
                invocationContext.reporting.retryCountRecorder?.record(retryCount)
                
                if let durationMetricDetails = durationMetricDetails {
                    durationMetricDetails.1.recordMicroseconds(Date().timeIntervalSince(durationMetricDetails.0))
                }
            }
            
            do {
                // submit the synchronous request
                try httpClient.executeSyncWithoutOutput(endpointOverride: endpointOverride,
                                                              endpointPath: endpointPath, httpMethod: httpMethod,
                                                              input: input, invocationContext: innerInvocationContext)
                
                // report success metric
                invocationContext.reporting.successCounter?.increment()
            } catch {
                // report success metric
                invocationContext.reporting.failureCounter?.increment()
                
                return try completeOnError(error: error)
            }
        }
        
        func completeOnError(error: Error) throws {
            let shouldRetryOnError = retryOnError(error)
            let logger = invocationContext.reporting.logger
            
            // if there are retries remaining and we should retry on this error
            if retriesRemaining > 0 && shouldRetryOnError {
                // determine the required interval
                let retryInterval = Int(retryConfiguration.getRetryInterval(retriesRemaining: retriesRemaining))
                
                let currentRetriesRemaining = retriesRemaining
                retriesRemaining -= 1
                
                logger.debug("Request failed with error: \(error). Remaining retries: \(currentRetriesRemaining). Retrying in \(retryInterval) ms.")
                usleep(useconds_t(retryInterval.milliFromMicroSeconds))
                logger.debug("Reattempting request due to remaining retries: \(currentRetriesRemaining)")
                return try executeSyncWithoutOutput()
            } else {
                if !shouldRetryOnError {
                    logger.debug("Request not retried due to error returned: \(error)")
                } else {
                    logger.debug("Request not retried due to maximum retries: \(retryConfiguration.numRetries)")
                }
                
                throw error
            }
        }
    }
    
    /**
     Submits a request that will return a response body to this client synchronously.

     - Parameters:
        - endpointPath: The endpoint path for this request.
        - httpMethod: The http method to use for this request.
        - input: the input body data to send with this request.
        - handlerDelegate: the delegate used to customize the request's channel handler.
        - retryConfiguration: the retry configuration for this request.
        - retryOnError: function that should return if the provided error is retryable.
     */
    func executeSyncRetriableWithoutOutput<InputType>(
        endpointOverride: URL? = nil,
        endpointPath: String,
        httpMethod: HTTPMethod,
        input: InputType,
        invocationContext: HTTPClientInvocationContext,
        retryConfiguration: HTTPClientRetryConfiguration,
        retryOnError: @escaping (Swift.Error) -> Bool) throws
        where InputType: HTTPRequestInputProtocol {

            let retriable = ExecuteSyncWithoutOutputRetriable<InputType>(
                endpointOverride: endpointOverride, endpointPath: endpointPath,
                httpMethod: httpMethod, input: input,
                invocationContext: invocationContext, httpClient: self,
                retryConfiguration: retryConfiguration,
                retryOnError: retryOnError)
            
            return try retriable.executeSyncWithoutOutput()
    }
}
