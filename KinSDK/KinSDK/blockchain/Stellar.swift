//
//  Stellar.swift
//  StellarKit
//
//  Created by Kin Foundation
//  Copyright © 2018 Kin Foundation. All rights reserved.
//

import Foundation
import KinUtil 

public protocol Account {
    var publicKey: String? { get }

    var sign: (([UInt8]) throws -> [UInt8])? { get }
}

/**
 `Stellar` provides an API for communicating with Stellar Horizon servers, with an emphasis on
 supporting non-native assets.
 */
public enum Stellar {
    public struct Node {
        public let baseURL: URL
        public let network: Network

        public init(baseURL: URL, network: Network = .testNet) {
            self.baseURL = baseURL
            self.network = network
        }
    }

    /**
     Generate a transaction envelope for the given account.

     - Parameter source: The account from which the payment will be made.
     - Parameter destination: The public key of the receiving account, as a base32 string.
     - Parameter amount: The amount to be sent.
     - Parameter memo: A short string placed in the MEMO field of the transaction.
     - Parameter node: An object describing the network endpoint.
     - Parameter fee: The fee in `Quark`s used when the transaction is not whitelisted.

     - Returns: A promise which will be signalled with the result of the operation.
     */
    public static func transaction(source: Account,
                                   destination: String,
                                   amount: Int64,
                                   memo: Memo = .MEMO_NONE,
                                   node: Node,
                                   fee: Quark) -> Promise<BaseTransaction> {
        return balance(account: destination, node: node)
            .then { _ -> Promise<BaseTransaction> in
                let op = Operation.payment(destination: destination,
                                           amount: amount,
                                           asset: .native,
                                           source: source)

                return TransactionBuilder(source: source, node: node)
                    .set(memo: memo)
                    .set(fee: fee)
                    .add(operation: op)
                    .build()
            }
            .then { transaction -> Promise<BaseTransaction> in
                try transaction.addSignature(account: source, networkId: node.network.id)

                return Promise(transaction)
            }
            .mapError({ error -> Error in
                switch error {
                case StellarError.missingAccount, StellarError.missingBalance:
                    return StellarError.destinationNotReadyForAsset(error)
                default:
                    return error
                }
            })
    }

    /**
     Obtain the balance.

     - parameter account: The `Account` whose balance will be retrieved.
     - parameter node: An object describing the network endpoint.

     - Returns: A promise which will be signalled with the result of the operation.
     */
    public static func balance(account: String, node: Node) -> Promise<Kin> {
        return accountDetails(account: account, node: node)
            .then { accountDetails in
                let p = Promise<Kin>()

                for balance in accountDetails.balances {
                    if balance.assetType == Asset.native.description {
                        return p.signal(balance.balanceNum)
                    }
                }

                return p.signal(StellarError.missingBalance)
        }
    }

    /**
     Obtain the aggregated balance.

     - parameter account: The `Account` whose aggregated balance will be retrieved.
     - parameter node: An object describing the network endpoint.

     - Returns: A promise which will be signalled with the result of the operation.
     */
    static func aggregatedBalance(account: String, node: Node) -> Promise<Kin> {
        let url = Endpoint(node.baseURL).account(account).aggregatedBalance().url

        return issue(request: URLRequest(url: url))
            .then { data -> Promise<AggregatedBalanceResponse> in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data) {
                    if case 400...404 = horizonError.status {
                        throw StellarError.invalidAccount
                    }
                    else {
                        throw StellarError.unknownError(horizonError)
                    }
                }

                return try Promise(JSONDecoder().decode(AggregatedBalanceResponse.self, from: data))
            }
            .then { aggregatedBalanceResponse -> Promise<Kin> in
                return Promise(aggregatedBalanceResponse.balance)
        }
    }

    /**
     Obtain the controlled accounts.

     - parameter account: The `Account` whose aggregated balance will be retrieved.
     - parameter node: An object describing the network endpoint.

     - Returns: A promise which will be signalled with the result of the operation.
     */
    static func controlledAccounts(account: String, node: Node) -> Promise<[ControlledAccount]> {
        let url = Endpoint(node.baseURL).account(account).controlledAccounts().url

        return issue(request: URLRequest(url: url))
            .then { data -> Promise<ControlledAccountsResponse> in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data) {
                    if case 400...404 = horizonError.status {
                        throw StellarError.invalidAccount
                    }
                    else {
                        throw StellarError.unknownError(horizonError)
                    }
                }

                return try Promise(JSONDecoder().decode(ControlledAccountsResponse.self, from: data))
            }
            .then { controlledAccountsResponse -> Promise<[ControlledAccount]> in
                return Promise(controlledAccountsResponse.controlledAccounts)
        }
    }

    static func accountData(account: String, node: Node) -> Promise<AccountData> {
        let url = Endpoint(node.baseURL).account(account).url

        return issue(request: URLRequest(url: url))
            .then { data -> Promise<AccountResponse> in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data) {
                    if case 400...404 = horizonError.status {
                        throw StellarError.invalidAccount
                    }
                    else {
                        throw StellarError.unknownError(horizonError)
                    }
                }

                return try Promise(JSONDecoder().decode(AccountResponse.self, from: data))
            }
            .then { accountResponse in
                return Promise(AccountData(publicAddress: accountResponse.keyPair,
                                           sequenceNumber: accountResponse.sequenceNumber,
                                           pagingToken: accountResponse.pagingToken,
                                           subentryCount: accountResponse.subentryCount,
                                           thresholds: accountResponse.thresholds,
                                           flags: accountResponse.flags,
                                           balances: accountResponse.balances,
                                           signers: accountResponse.signers,
                                           data: accountResponse.data))
        }
    }

    /**
     Obtain details for the given account.

     - parameter account: The `Account` whose details will be retrieved.
     - parameter node: An object describing the network endpoint.

     - Returns: A promise which will be signalled with the result of the operation.
     */
    public static func accountDetails(account: String, node: Node) -> Promise<AccountDetails> {
        let url = Endpoint(node.baseURL).account(account).url

        return issue(request: URLRequest(url: url))
            .then { data in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data) {
                    if horizonError.status == 404 {
                        throw StellarError.missingAccount
                    }
                    else {
                        throw StellarError.unknownError(horizonError)
                    }
                }

                return try Promise<AccountDetails>(JSONDecoder().decode(AccountDetails.self, from: data))
        }
    }

    /**
     Observe transactions on the given node.  When `account` is non-`nil`, observations are
     limited to transactions involving the given account.

     - parameter account: The `Account` whose transactions will be observed.  Optional.
     - parameter lastEventId: If non-`nil`, only transactions with a later event Id will be observed.
     The string _now_ will only observe transactions completed after observation begins.
     - parameter node: An object describing the network endpoint.

     - Returns: An instance of `TxWatch`, which contains an `Observable` which emits `TxInfo` objects.
     */
    public static func txWatch(account: String? = nil,
                               lastEventId: String?,
                               node: Node) -> EventWatcher<TxEvent> {
        let url = Endpoint(node.baseURL).account(account).transactions().cursor(lastEventId).url

        return EventWatcher(eventSource: StellarEventSource(url: url))
    }

    /**
     Observe payments on the given node.  When `account` is non-`nil`, observations are
     limited to payments involving the given account.

     - parameter account: The `Account` whose payments will be observed.  Optional.
     - parameter lastEventId: If non-`nil`, only payments with a later event Id will be observed.
     The string _now_ will only observe payments made after observation begins.
     - parameter node: An object describing the network endpoint.

     - Returns: An instance of `PaymentWatch`, which contains an `Observable` which emits `PaymentEvent` objects.
     */
    public static func paymentWatch(account: String? = nil,
                                    lastEventId: String?,
                                    node: Node) -> EventWatcher<PaymentEvent> {
        let url = Endpoint(node.baseURL).account(account).payments().cursor(lastEventId).url

        return EventWatcher(eventSource: StellarEventSource(url: url))
    }

    //MARK: -

    public static func sequence(account: String, seqNum: UInt64 = 0, node: Node) -> Promise<UInt64> {
        if seqNum > 0 {
            return Promise().signal(seqNum)
        }

        return accountDetails(account: account, node: node)
            .then { accountDetails in
                return Promise<UInt64>().signal(accountDetails.seqNum + 1)
        }
    }

    public static func networkParameters(node: Node) -> Promise<NetworkParameters> {
        let url = Endpoint(node.baseURL).ledgers().order(.descending).limit(1).url

        return issue(request: URLRequest(url: url))
            .then { data in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data) {
                    throw StellarError.unknownError(horizonError)
                }

                return try Promise(JSONDecoder().decode(NetworkParameters.self, from: data))
        }
    }

    public static func sign(transaction: Transaction, signer: Account, node: Node) throws -> Transaction.Envelope {
        var transaction = transaction
        try transaction.sign(account: signer, networkId: node.network.id)
        return transaction.envelope()
    }

    public static func postTransaction(envelope: Transaction.Envelope, node: Node) -> Promise<String> {
        let envelopeData: Data
        do {
            envelopeData = try Data(XDREncoder.encode(envelope))
        }
        catch {
            return Promise<String>(error)
        }

        guard let urlEncodedEnvelope = envelopeData.base64EncodedString().urlEncoded else {
            return Promise<String>(StellarError.urlEncodingFailed)
        }

        guard let httpBody = ("tx=" + urlEncodedEnvelope).data(using: .utf8) else {
            return Promise<String>(StellarError.dataEncodingFailed)
        }

        var request = URLRequest(url: Endpoint(node.baseURL).transactions().url)
        request.httpMethod = "POST"
        request.httpBody = httpBody

        return issue(request: request)
            .then { data in
                if let horizonError = try? JSONDecoder().decode(HorizonError.self, from: data),
                    let resultXDR = horizonError.extras?.resultXDR,
                    let error = errorFromResponse(resultXDR: resultXDR)
                {
                    throw error
                }

                do {
                    let txResponse = try JSONDecoder().decode(TransactionResponse.self, from: data)

                    return Promise<String>(txResponse.hash)
                }
                catch {
                    throw error
                }
        }
    }

    /**
     Get the minimum fee for sending a transaction.

     - Parameter node: An object describing the network endpoint.

     - Returns: The minimum fee needed to send a transaction.
     */
    public static func minFee(node: Node) -> Promise<Quark> {
        let promise = Promise<Quark>()

        Stellar.networkParameters(node: node)
            .then { networkParameters in
                promise.signal(networkParameters.baseFee)
            }
            .error { error in
                promise.signal(error)
        }

        return promise
    }

    static func issue(request: URLRequest) -> Promise<Data> {
        let p = Promise<Data>()

        URLSession
            .shared
            .kinDataTask(with: request, completionHandler: { (data, _, error) in
                if let error = error {
                    p.signal(error)

                    return
                }

                guard let data = data else {
                    p.signal(StellarError.internalInconsistency)

                    return
                }

                p.signal(data)
            })
            .resume()

        return p
    }
}
