import Foundation
import CoreLocation
import CoreMotion

final class RideSensorManager: NSObject, ObservableObject {
    @Published var speedKmh: Double = 0
    @Published var maxSpeedKmh: Double = 0
    @Published var rollDegrees: Double = 0
    @Published var pitchDegrees: Double = 0
    @Published var gForce: Double = 0

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.05
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, let motion else { return }

                self.rollDegrees = motion.attitude.roll * 180 / .pi
                self.pitchDegrees = motion.attitude.pitch * 180 / .pi

                let x = motion.userAcceleration.x
                let y = motion.userAcceleration.y
                let z = motion.userAcceleration.z
                self.gForce = sqrt(x * x + y * y + z * z)
            }
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
    }
}

extension RideSensorManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }

        let speedMps = max(latest.speed, 0)
        let kmh = speedMps * 3.6

        speedKmh = kmh
        if kmh > maxSpeedKmh {
            maxSpeedKmh = kmh
        }
    }
}
