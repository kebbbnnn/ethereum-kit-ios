import RxSwift
import BigInt

class InfuraApiProvider {
    private let networkManager: NetworkManager
    private let network: INetwork

    private let credentials: (id: String, secret: String?)
    private let address: Data

    init(networkManager: NetworkManager, network: INetwork, credentials: (id: String, secret: String?), address: Data) {
        self.networkManager = networkManager
        self.network = network
        self.credentials = credentials
        self.address = address
    }

}

extension InfuraApiProvider {

    private var infuraBaseUrl: String {
        switch network {
        case is Ropsten: return "https://ropsten.infura.io"
        case is Kovan: return "https://kovan.infura.io"
        default: return "https://mainnet.infura.io"
        }
    }

    private func infuraSingle<T>(method: String, params: [Any], mapper: @escaping (Any) -> T?) -> Single<T> {
        let urlString = "\(infuraBaseUrl)/v3/\(credentials.id)"

        let basicAuth = credentials.secret.map { (user: "", password: $0) }

        let parameters: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1
        ]

        return networkManager.single(urlString: urlString, httpMethod: .post, basicAuth: basicAuth, parameters: parameters, mapper: mapper)
    }

    private func infuraVoidSingle(method: String, params: [Any]) -> Single<Void> {
        infuraSingle(method: method, params: params) { data -> [String: Any]? in
            data as? [String: Any]
        }.flatMap { data -> Single<Void> in
            guard data["result"] != nil else {
                return Single.error(SendError.infuraError(message: (data["error"] as? [String: Any])?["message"] as? String ?? ""))
            }

            return Single.just(())
        }
    }

    private func infuraIntSingle(method: String, params: [Any]) -> Single<Int> {
        infuraSingle(method: method, params: params) { data -> Int? in
            if let map = data as? [String: Any], let result = map["result"] as? String, let int = Int(result.stripHexPrefix(), radix: 16) {
                return int
            }
            return nil
        }
    }

    private func infuraBigIntSingle(method: String, params: [Any]) -> Single<BigUInt> {
        infuraSingle(method: method, params: params) { data -> BigUInt? in
            if let map = data as? [String: Any], let result = map["result"] as? String, let bigInt = BigUInt(result.stripHexPrefix(), radix: 16) {
                return bigInt
            }
            return nil
        }
    }

    private func infuraStringSingle(method: String, params: [Any]) -> Single<String> {
        infuraSingle(method: method, params: params) { data -> String? in
            if let map = data as? [String: Any], let result = map["result"] as? String {
                return result
            }
            return nil
        }
    }

}

extension InfuraApiProvider: IRpcApiProvider {

    var source: String {
        "infura.io"
    }

    func lastBlockHeightSingle() -> Single<Int> {
        infuraIntSingle(method: "eth_blockNumber", params: [])
    }

    func transactionCountSingle() -> Single<Int> {
        infuraIntSingle(method: "eth_getTransactionCount", params: [address.toHexString(), "pending"])
    }

    func balanceSingle() -> Single<BigUInt> {
        infuraBigIntSingle(method: "eth_getBalance", params: [address.toHexString(), "latest"])
    }

    func sendSingle(signedTransaction: Data) -> Single<Void> {
        infuraVoidSingle(method: "eth_sendRawTransaction", params: [signedTransaction.toHexString()])
    }

    func getLogs(address: Data?, fromBlock: Int?, toBlock: Int?, topics: [Any?]) -> Single<[EthereumLog]> {
        var toBlockStr = "latest"
        if let toBlockInt = toBlock {
            toBlockStr = "0x" + String(toBlockInt, radix: 16)
        }
        var fromBlockStr = "latest"
        if let fromBlockInt = fromBlock {
            fromBlockStr = "0x" + String(fromBlockInt, radix: 16)
        }

        let jsonTopics: [Any?] = topics.map {
            if let array = $0 as? [Data?] {
                return array.map { topic -> String? in
                    topic?.toHexString()
                }
            } else if let data = $0 as? Data {
                return data.toHexString()
            } else {
                return nil
            }
        }

        let params: [String: Any] = [
            "fromBlock": fromBlockStr,
            "toBlock": toBlockStr,
            "address": address?.toHexString() as Any,
            "topics": jsonTopics
        ]

        return infuraSingle(method: "eth_getLogs", params: [params]) {data -> [EthereumLog] in
            if let map = data as? [String: Any], let result = map["result"] as? [Any] {
                return result.compactMap { EthereumLog(json: $0) }
            }
            return []
        }
    }

    func transactionReceiptStatusSingle(transactionHash: Data) -> Single<TransactionStatus> {
        infuraSingle(method: "eth_getTransactionReceipt", params: [transactionHash.toHexString()]) { data -> TransactionStatus in
            guard let map = data as? [String: Any],
                  let log = map["result"] as? [String: Any],
                  let statusString = log["status"] as? String,
                  let success = Int(statusString.stripHexPrefix(), radix: 16) else {
                return .notFound
            }
            return success == 0 ? .failed : .success
        }
    }

    func transactionExistSingle(transactionHash: Data) -> Single<Bool> {
        infuraSingle(method: "eth_getTransactionByHash", params: [transactionHash.toHexString()]) {data -> Bool in
            guard let map = data as? [String: Any], let _ = map["result"] as? [String: Any] else {
                return false
            }
            return true
        }
    }

    func getStorageAt(contractAddress: String, position: String, blockNumber: Int?) -> Single<String> {
        infuraStringSingle(method: "eth_getStorageAt", params: [contractAddress, position, "latest"])
    }

    func call(contractAddress: String, data: String, blockNumber: Int?) -> Single<String> {
        infuraStringSingle(method: "eth_call", params: [["to": contractAddress, "data": data], "latest"])
    }

    func getEstimateGas(from: String?, contractAddress: String, amount: BigUInt?, gasLimit: Int?, gasPrice: Int?, data: String?) -> Single<String> {
        var params = [String: Any]()
        if let from = from {
            params["from"] = from.lowercased()
        }
        if let amount = amount {
            params["value"] = "0x" + amount.serialize().toRawHexString().removeLeadingZeros()
        }
        if let gasLimit = gasLimit {
            params["gas"] = "0x" + String(gasLimit, radix: 16).removeLeadingZeros()
        }
        if let gasPrice = gasPrice {
            params["gas"] = "0x" + String(gasPrice, radix: 16).removeLeadingZeros()
        }
        params["to"] = contractAddress.lowercased()
        params["data"] = data

        return infuraSingle(method: "eth_estimateGas", params: [params]) { data -> InfuraGasLimitResponse? in
            guard let map = data as? [String: Any] else {
                return nil
            }
            if let result = map["result"] as? String {
                return InfuraGasLimitResponse(value: result, error: nil)
            } else if let error = map["error"] as? [String: Any],
                      let message = error["message"] as? String,
                      let codeString = error["code"] as? String,
                      let code = Int(codeString) {
                return InfuraGasLimitResponse(value: nil, error: InfuraError(errorMessage: message, errorCode: code))
            }
            return nil
        }.flatMap { response -> Single<String> in
            if let value = response.value {
                return Single.just(value)
            } else if let error = response.error {
                return Single.error(error)
            }
            return Single.error(NetworkError.mappingError)
        }
    }

    func getBlock(byNumber number: Int) -> Single<Block> {
        infuraSingle(method: "eth_getBlockByNumber", params: ["0x" + String(number, radix: 16), false]) {data -> Block? in
            if let map = data as? [String: Any], let result = map["result"] {
                return Block(json: result)
            }
            return nil
        }
    }

}
