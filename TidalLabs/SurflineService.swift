import Foundation

enum SurflineService {
    private struct Spot: Decodable {
        let name: String
    }
    private struct Response: Decodable {
        let contains: [Spot]?
    }

    static func nearestSpotName(lat: Double, lon: Double) async -> String? {
        var comps = URLComponents(string: "https://services.surfline.com/taxonomy")!
        comps.queryItems = [
            URLQueryItem(name: "type", value: "spot"),
            URLQueryItem(name: "maxDistance", value: "25"),
            URLQueryItem(name: "unit", value: "mi"),
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.contains?.first?.name
    }
}
