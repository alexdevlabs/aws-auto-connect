/// Every connector type the app knows. To add one, create Connectors/<Name>/ with a class that
/// conforms to `Connector` and list it here.
enum ConnectorRegistry {
    @MainActor static let types: [any Connector.Type] = [
        AWSSSOConnector.self,
        AWSVPNConnector.self,
        GrafanaConnector.self,
    ]

    @MainActor static func type(named name: String) -> (any Connector.Type)? {
        types.first { $0.type == name }
    }
}
