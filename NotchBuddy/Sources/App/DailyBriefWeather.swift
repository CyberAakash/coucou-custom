#if !APPSTORE
import Foundation

// coucou-custom fork: the Daily brief's weather, from Open-Meteo (no key, no account) for the city
// in Settings → Voice → Your city — now, the day's high and low, the rain, and four hours of it.
// Asked only when the brief is built with its weather section on and a city named.

struct DailyBriefWeather: Equatable {
    struct Hour: Equatable {
        let hour: Int
        let temp: Int
        let code: Int
    }

    let city: String
    let now: Int
    let code: Int
    let high: Int
    let low: Int
    let rainChance: Int?
    let rainFrom: Int?    // the first hour with a 50 % chance of rain or more
    let hours: [Hour]

    /// WMO weather codes, as Open-Meteo sends them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 63, 65, 66, 67: "Rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorms"
        default: "Weather"
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func fetch(city: String) async -> DailyBriefWeather? {
        let session = URLSession(configuration: .ephemeral)
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
        guard let gurl = geo.url,
              let (gdata, _) = try? await session.data(for: URLRequest(url: gurl, timeoutInterval: 8)),
              let gjson = try? JSONSerialization.jsonObject(with: gdata) as? [String: Any],
              let place = (gjson["results"] as? [[String: Any]])?.first,
              let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double else { return nil }
        var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        f.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
        ]
        guard let furl = f.url,
              let (data, _) = try? await session.data(for: URLRequest(url: furl, timeoutInterval: 8)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json, city: place["name"] as? String ?? city)
    }

    /// Split from fetch for the tests' sake: Open-Meteo's JSON to the brief's weather.
    static func parse(_ json: [String: Any], city: String) -> DailyBriefWeather? {
        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        guard let current = json["current"] as? [String: Any], let now = num(current["temperature_2m"]),
              let daily = json["daily"] as? [String: Any],
              let high = (daily["temperature_2m_max"] as? [Any])?.first.flatMap(num),
              let low = (daily["temperature_2m_min"] as? [Any])?.first.flatMap(num) else { return nil }
        let rain = (daily["precipitation_probability_max"] as? [Any])?.first.flatMap(num).map { Int($0.rounded()) }
        var hours: [Hour] = []
        var rainFrom: Int?
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [Any],
           let codes = hourly["weather_code"] as? [Any] {
            let chances = hourly["precipitation_probability"] as? [Any] ?? []
            for (i, t) in times.enumerated() {
                // "2026-10-23T15:00"
                guard let hour = Int(t.dropFirst(11).prefix(2)) else { continue }
                if [9, 12, 15, 18].contains(hour), i < temps.count, i < codes.count,
                   let temp = num(temps[i]), let code = num(codes[i]) {
                    hours.append(Hour(hour: hour, temp: Int(temp.rounded()), code: Int(code)))
                }
                if rainFrom == nil, hour >= 6, i < chances.count, let c = num(chances[i]), c >= 50 { rainFrom = hour }
            }
        }
        return DailyBriefWeather(city: city, now: Int(now.rounded()), code: Int(num(current["weather_code"]) ?? 0),
                                 high: Int(high.rounded()), low: Int(low.rounded()), rainChance: rain,
                                 rainFrom: rainFrom, hours: hours)
    }

    /// "High 29° · Low 19° · Rain likely after 17:00".
    var line: String {
        var parts = ["High \(high)°", "Low \(low)°"]
        if let r = rainFrom { parts.append(String(format: "Rain likely after %02d:00", r)) }
        else if let c = rainChance, c > 0 { parts.append("Rain \(c)%") }
        return parts.joined(separator: " · ")
    }
}
#endif
