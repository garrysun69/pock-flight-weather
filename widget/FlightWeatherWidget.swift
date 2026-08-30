//
//  FlightWeatherWidget.swift
//  Pock widget: погода для льотних операцій
//
//  Тягне дані з локального сервісу http://127.0.0.1:8787/weather
//  і показує в Touch Bar: температура | вітер (напрямок/швидкість/пориви) | статус.
//
//  Жести:
//    tap        -> перемикає режим (compact / wind / forecast)
//    long press -> примусове оновлення
//

import Cocoa
import PockKit

// MARK: - Модель

struct FlightWeather: Decodable {
    let status: String
    let reasons: [String]?
    let short: String?
    let temperature: Double
    let apparentTemperature: Double
    let windSpeed: Double
    let windGusts: Double
    let windDirection: Double
    let windDirectionText: String
    let cloudCover: Double
    let visibility: Double?
    let precipitation: Double
    let condition: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case status
        case reasons
        case short
        case temperature
        case apparentTemperature   = "apparent_temperature"
        case windSpeed             = "wind_speed"
        case windGusts             = "wind_gusts"
        case windDirection         = "wind_direction"
        case windDirectionText     = "wind_direction_text"
        case cloudCover            = "cloud_cover"
        case visibility
        case precipitation
        case condition
        case updatedAt             = "updated_at"
    }

    var statusColor: NSColor {
        switch status {
        case "good":     return NSColor.systemGreen
        case "marginal": return NSColor.systemYellow
        case "no-go":    return NSColor.systemRed
        default:         return NSColor.systemGray
        }
    }

    /// Стрілка напрямку вітру (звідки дме)
    var windArrow: String {
        let arrows = ["↓", "↙", "←", "↖", "↑", "↗", "→", "↘"]
        let idx = Int((windDirection.truncatingRemainder(dividingBy: 360)) / 45.0 + 0.5) % 8
        return arrows[idx]
    }
}

// MARK: - Клієнт сервісу

final class WeatherClient {
    static let endpoint = URL(string: "http://127.0.0.1:8787/weather")!

    func load(completion: @escaping (Result<FlightWeather, Error>) -> Void) {
        var request = URLRequest(url: WeatherClient.endpoint)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "FlightWeather", code: -1,
                                                userInfo: [NSLocalizedDescriptionKey: "no data"])))
                }
                return
            }
            do {
                let model = try JSONDecoder().decode(FlightWeather.self, from: data)
                DispatchQueue.main.async { completion(.success(model)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }
}

// MARK: - View

final class FlightWeatherView: NSView {

    enum Mode: Int, CaseIterable {
        case compact, wind, detail
    }

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "…")
    private var mode: Mode = .compact
    private var model: FlightWeather?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func nextMode() {
        let all = Mode.allCases
        let current = all.firstIndex(of: mode) ?? 0
        mode = all[(current + 1) % all.count]
        render()
    }

    func apply(_ model: FlightWeather?) {
        self.model = model
        render()
    }

    func showError(_ message: String) {
        self.model = nil
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        label.stringValue = "wx: \(message)"
    }

    private func render() {
        guard let m = model else { return }
        dot.layer?.backgroundColor = m.statusColor.cgColor

        switch mode {
        case .compact:
            label.stringValue = String(format: "%.0f°  %@ %.0f/%.0f m/s",
                                       m.temperature, m.windArrow, m.windSpeed, m.windGusts)
        case .wind:
            let vis = m.visibility.map { String(format: "%.0f km", $0 / 1000) } ?? "—"
            label.stringValue = String(format: "%@ %.0f° %.1f g%.1f  vis %@",
                                       m.windDirectionText, m.windDirection,
                                       m.windSpeed, m.windGusts, vis)
        case .detail:
            let reason = (m.reasons?.isEmpty == false)
                ? m.reasons!.joined(separator: ", ")
                : m.condition
            label.stringValue = "\(m.status.uppercased()): \(reason)"
        }
    }
}

// MARK: - Widget

class FlightWeatherWidget: PKWidget {

    static var identifier: String = "com.garrysun.flightweather"
    var customizationLabel: String! = "Flight Weather"
    var view: NSView!

    private let client = WeatherClient()
    private var timer: Timer?
    private var weatherView: FlightWeatherView!

    required init() {
        weatherView = FlightWeatherView(frame: NSRect(x: 0, y: 0, width: 190, height: 30))
        view = weatherView

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = .direct
        weatherView.addGestureRecognizer(tap)

        let longPress = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.allowedTouchTypes = .direct
        longPress.minimumPressDuration = 0.6
        weatherView.addGestureRecognizer(longPress)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    @objc private func handleTap() {
        weatherView.nextMode()
    }

    @objc private func handleLongPress(_ recognizer: NSPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        refresh()
    }

    private func refresh() {
        client.load { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let model):
                self.weatherView.apply(model)
            case .failure:
                self.weatherView.showError("service offline")
            }
        }
    }
}
