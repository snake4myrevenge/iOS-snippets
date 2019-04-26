//
//  ApiClient.swift
//
//  Created by Alexander Kuprikov on 4/23/19.
//  All rights reserved.
//

import Foundation
import Alamofire
import NotificationBannerSwift
import Firebase

enum Result<T> {
    case success(T)
    case failure(Error)
}

final class AlamofireRequestRetrier: RequestRetrier, RequestAdapter {
    
    private let reachabilityManager = NetworkReachabilityManager()
    
    func adapt(_ urlRequest: URLRequest) throws -> URLRequest {
        let reachable = reachabilityManager?.isReachable ?? true
        if !reachable {
            throw NSError.createError(-1009)
        }
        
        var mutableRequest = urlRequest
        mutableRequest.allHTTPHeaderFields?["Authorization"] = "Bearer \(KeychainManager.shared().token ?? "")"
        return mutableRequest
    }
    
    func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion) {
        guard let response = request.response, response.statusCode == 401 else {
            completion(false, 0.0)
            return
        }
        
        if request.retryCount == 3 { completion(false, 0.0); return }
        
        Auth.auth().currentUser?.getIDTokenForcingRefresh(true, completion: { token, error in
            KeychainManager.shared().saveToken(token ?? "")
            manager.session.configuration.httpAdditionalHeaders?["Authorization"] = "Bearer \(token ?? "")"
            completion(true, 0.0)
        })
    }
}

class ApiClient {
    
    // MARK: - Singleton.
    
    private static let sharedInstance = ApiClient()
    
    private init() {
        let configuration = URLSessionConfiguration.default
        var headers = SessionManager.defaultHTTPHeaders
        if let token = KeychainManager.shared().token {
            headers.merge(zip(["Authorization"], ["Bearer \(token)"])) { (current, _) in current }
        }
        configuration.httpAdditionalHeaders = headers
        sessionManager = SessionManager(configuration: configuration)
        let retrierAdaptor = AlamofireRequestRetrier()
        sessionManager.retrier = retrierAdaptor
        sessionManager.adapter = retrierAdaptor
    }
    
    class func shared() -> ApiClient { return self.sharedInstance }
    
    // MARK: - Public properties
    
    class EmptyResponse: Codable {}
    
    enum Errors: Error {
        case badRequest
        case responseNotValidJson
        case noDataReturned
        case unknownError
    }
    
    // MARK: - Private properties
    
    private let sessionManager: SessionManager
    private let baseURL: String = ""
    private var shouldShowNotificationBanner: Bool = true
    
    // MARK: - Public API
    
    @discardableResult
    func request<T: Codable>(apiMethod: String,
                             method: HTTPMethod = .get,
                             parameters: Parameters?,
                             encoding: ParameterEncoding = URLEncoding.default,
                             headers: HTTPHeaders? = nil,
                             responseClass: T.Type,
                             completion: @escaping (Result<T>) -> Void) -> DataRequest {
        return sessionManager
            .request(urlForApiMethod(apiMethod), method: method, parameters: parameters, encoding: encoding, headers: headers)
            .validate(statusCode: 200..<300)
            .response { response in
                if let error = response.error as NSError? { // Here we failed validation or it's internal error
                    if let responseStatusCode = response.response?.statusCode { // Here handle external errors
                        switch responseStatusCode {
                        default: self.showBanner(title: "API Error", subtitle: "Status code: \(responseStatusCode)")
                        }
                        completion(.failure(NSError.createError(responseStatusCode)))
                    } else { // Here handle internal alamofire errors
                        switch error.code {
                        case -999: return
                        case -1009: self.showBanner(title: "No internet connection", subtitle: "The Internet connection appears to be offline")
                        default: self.showBanner(title: "API Error", subtitle: error.localizedDescription)
                        }
                        completion(.failure(error))
                    }
                    return
                }
                
                guard let data = response.data else {
                    self.showBanner(title: "API Error", subtitle: "Server returns no data")
                    completion(.failure(Errors.noDataReturned as NSError))
                    return
                }
                
                let decoder = JSONDecoder()
                guard let responseObject = try? decoder.decode(T.self, from: data) else {
                    self.showBanner(title: "API Error", subtitle: "Failed to parse server response")
                    completion(.failure(Errors.responseNotValidJson as NSError))
                    return
                }
                completion(.success(responseObject))
        }
    }
    
    // MARK: - Private API
    
    private func urlForApiMethod(_ apiMethod: String) -> String { return baseURL + apiMethod }
    
    private func showBanner(title: String, subtitle: String) {
        if !shouldShowNotificationBanner { return }
        let banner = NotificationBanner(title: title, subtitle: subtitle, style: .warning)
        banner.delegate = self
        banner.duration = 3.0
        banner.onTap = { banner.dismiss() }
        banner.show()
    }
    
    private func emptyResult<T>() -> T where T : Decodable {
        return EmptyResponse() as! T
    }
    
}

extension ApiClient: NotificationBannerDelegate {
    
    func notificationBannerWillAppear(_ banner: BaseNotificationBanner) { shouldShowNotificationBanner = false }
    
    func notificationBannerDidAppear(_ banner: BaseNotificationBanner) {}
    
    func notificationBannerWillDisappear(_ banner: BaseNotificationBanner) { shouldShowNotificationBanner = true }
    
    func notificationBannerDidDisappear(_ banner: BaseNotificationBanner) {}
}

extension NSError {
    static func createError(_ statusCode: Int) -> NSError {
        return NSError(domain: "", code: statusCode, userInfo: nil)
    }
}
