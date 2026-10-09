import AppKit
import SwiftUI

/// The whole world, small, with a pin where the images were taken. A click
/// opens the place in Google Maps in the browser.
///
/// Drawn here from Natural Earth's coastlines (public domain, `WorldLand.json`),
/// not by MapKit: MapKit will not zoom a box this small out to the whole
/// world, and its globe is lit as the Earth is now, half of it night.
struct LocationMap: View {

    let location: ExifEditorModel.Location

    @State private var hovering = false

    /// The latitudes shown: Antarctica and the far Arctic left off, which
    /// no pin is likely to need, and which would make the map tall.
    nonisolated static let north = 84.0
    nonisolated static let south = -58.0

    static let size = CGSize(width: 320, height: (320 * (north - south) / 360).rounded())

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(.blue.opacity(0.14)))
                var land = Path()
                for ring in Self.land {
                    guard let first = ring.first else { continue }
                    land.move(to: Self.point(first, in: size))
                    for corner in ring.dropFirst() { land.addLine(to: Self.point(corner, in: size)) }
                    land.closeSubpath()
                }
                context.fill(land, with: .color(.green.opacity(0.4)))
                context.stroke(land, with: .color(.green.opacity(0.6)), lineWidth: 0.5)
            }
            Image(systemName: "mappin")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.red)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(Self.point(CGPoint(x: location.longitude, y: location.latitude),
                                     in: Self.size))
                // The pin's point, not its middle, on the place.
                .offset(y: -9)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(Self.googleMaps(location)) }
        .onHover { inside in
            if inside, !hovering { NSCursor.pointingHand.push() }
            if !inside, hovering { NSCursor.pop() }
            hovering = inside
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .help("Open \(Self.text(location)) in Google Maps")
    }

    /// Longitude and latitude, as x and y, to a place on the map: east to
    /// the right, north up, every degree the same size.
    nonisolated static func point(_ degrees: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (degrees.x + 180) / 360 * size.width,
                y: (north - degrees.y) / (north - south) * size.height)
    }

    /// Each piece of land, as its outline's corners: longitude, latitude.
    nonisolated static let land: [[CGPoint]] = {
        guard let url = Bundle.main.url(forResource: "WorldLand", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rings = try? JSONDecoder().decode([[Double]].self, from: data)
        else { return [] }
        return rings.map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        }
    }()

    /// `47.497900,19.040200`: a point, not a locale's way of writing numbers.
    nonisolated static func text(_ location: ExifEditorModel.Location) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"),
               location.latitude, location.longitude)
    }

    nonisolated static func googleMaps(_ location: ExifEditorModel.Location) -> URL {
        var components = URLComponents(string: "https://www.google.com/maps/search/")!
        components.queryItems = [URLQueryItem(name: "api", value: "1"),
                                 URLQueryItem(name: "query", value: text(location))]
        return components.url!
    }
}
