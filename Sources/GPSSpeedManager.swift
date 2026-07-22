import Foundation
import CoreLocation
import Combine

final class GPSSpeedManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var speedKmh: Double = 0
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var isActive: Bool = false

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 1
        authStatus = locationManager.authorizationStatus
    }

    func start() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            isActive = true
        default:
            isActive = false
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        isActive = false
        speedKmh = 0
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            isActive = true
        } else {
            isActive = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let ms = max(0, loc.speed)   // m/s, -1 means invalid
        speedKmh = loc.speed >= 0 ? (ms * 3.6 * 10).rounded() / 10 : speedKmh
    }
}
