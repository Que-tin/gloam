// The "gloam" wordmark, drawn from its outline: the same path as assets/wordmark-on-*.svg (keep
// them in step), so the popover's header and the README carry one mark. A shape rather than an
// image, so it stays crisp at any size and takes the ink it's given. The outline uses only
// absolute M, Q, H, V and Z, which is all `path(in:)` reads.

import SwiftUI

nonisolated struct Wordmark: Shape {
    /// The outline's own box (the SVG's viewBox): x 1.86…279.31, y −72.75…21.58 (baseline at 0).
    static let box = CGRect(x: 1.86, y: -72.75, width: 277.45, height: 94.33)
    static let aspect = box.width / box.height

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.box.minX, y: -Self.box.minY)
        return Self.outline.applying(transform)
    }

    private static let outline: Path = {
        var path = Path(), point = CGPoint.zero, i = data.startIndex
        func number() -> CGFloat {
            while i < data.endIndex, data[i] == " " { i = data.index(after: i) }
            let start = i
            while i < data.endIndex, "-.0123456789".contains(data[i]) { i = data.index(after: i) }
            return CGFloat(Double(data[start..<i]) ?? 0)
        }
        while i < data.endIndex {
            let command = data[i]
            i = data.index(after: i)
            switch command {
            case "M": point = CGPoint(x: number(), y: number()); path.move(to: point)
            case "Q":
                let control = CGPoint(x: number(), y: number())
                point = CGPoint(x: number(), y: number())
                path.addQuadCurve(to: point, control: control)
            case "H": point.x = number(); path.addLine(to: point)
            case "V": point.y = number(); path.addLine(to: point)
            case "Z": path.closeSubpath()
            default: break
            }
        }
        return path
    }()

    private static let data = "M29.88 21.58Q17.58 21.58 10.67 16.5Q3.76 11.43 3.22 3.52H22.07Q22.36 5.27 23.49 6.35Q24.61 7.42 26.42 7.91Q28.22 8.4 30.47 8.4Q34.28 8.4 36.77 6.54Q39.26 4.69 39.26 -0.1V-9.38H38.67Q37.65 -6.64 35.42 -4.69Q33.2 -2.73 30.13 -1.71Q27.05 -0.68 23.34 -0.68Q17.53 -0.68 12.65 -3.39Q7.76 -6.1 4.81 -11.96Q1.86 -17.82 1.86 -27.25Q1.86 -37.16 4.96 -43.33Q8.06 -49.51 12.94 -52.39Q17.82 -55.27 23.24 -55.27Q27.29 -55.27 30.37 -53.88Q33.45 -52.49 35.57 -50.15Q37.7 -47.8 38.77 -45.02H39.16V-54.59H58.59V-0.1Q58.59 6.79 55 11.65Q51.42 16.5 44.97 19.04Q38.53 21.58 29.88 21.58ZM30.57 -14.65Q34.62 -14.65 36.94 -17.99Q39.26 -21.34 39.26 -27.25Q39.26 -31.3 38.21 -34.2Q37.16 -37.11 35.23 -38.67Q33.3 -40.23 30.57 -40.23Q27.88 -40.23 25.98 -38.67Q24.07 -37.11 23.07 -34.2Q22.07 -31.3 22.07 -27.25Q22.07 -23.24 23.07 -20.41Q24.07 -17.58 25.98 -16.11Q27.88 -14.65 30.57 -14.65ZM81.84 -72.75V0H62.21V-72.75ZM111.73 0.98Q102.84 0.98 96.52 -2.56Q90.19 -6.1 86.85 -12.43Q83.5 -18.75 83.5 -27.15Q83.5 -35.55 86.85 -41.87Q90.19 -48.19 96.52 -51.73Q102.84 -55.27 111.73 -55.27Q120.61 -55.27 126.94 -51.73Q133.26 -48.19 136.6 -41.87Q139.95 -35.55 139.95 -27.15Q139.95 -18.75 136.6 -12.43Q133.26 -6.1 126.94 -2.56Q120.61 0.98 111.73 0.98ZM111.82 -13.67Q114.36 -13.67 116.17 -15.28Q117.98 -16.89 118.95 -19.95Q119.93 -23 119.93 -27.25Q119.93 -31.54 118.95 -34.52Q117.98 -37.5 116.17 -39.06Q114.36 -40.62 111.82 -40.62Q109.24 -40.62 107.36 -39.06Q105.48 -37.5 104.5 -34.52Q103.52 -31.54 103.52 -27.25Q103.52 -23 104.5 -19.95Q105.48 -16.89 107.36 -15.28Q109.24 -13.67 111.82 -13.67ZM156.85 0.88Q151.62 0.88 147.59 -0.85Q143.57 -2.59 141.32 -6.1Q139.07 -9.62 139.07 -15.04Q139.07 -19.53 140.59 -22.71Q142.1 -25.88 144.84 -27.91Q147.57 -29.93 151.21 -31.03Q154.85 -32.13 159.09 -32.42Q163.68 -32.76 166.44 -33.25Q169.2 -33.74 170.45 -34.69Q171.69 -35.64 171.69 -37.21V-37.4Q171.69 -39.5 170.08 -40.65Q168.47 -41.8 165.93 -41.8Q163.1 -41.8 161.34 -40.58Q159.58 -39.36 159.19 -36.82H141.22Q141.56 -41.8 144.37 -46Q147.18 -50.2 152.62 -52.73Q158.07 -55.27 166.22 -55.27Q172.03 -55.27 176.67 -53.91Q181.31 -52.54 184.58 -50.1Q187.85 -47.66 189.59 -44.41Q191.32 -41.16 191.32 -37.4V0H172.96V-7.71H172.57Q170.91 -4.64 168.59 -2.76Q166.27 -0.88 163.34 0Q160.41 0.88 156.85 0.88ZM163.2 -11.52Q165.44 -11.52 167.42 -12.45Q169.4 -13.38 170.64 -15.11Q171.89 -16.85 171.89 -19.34V-23.83Q171.11 -23.54 170.23 -23.24Q169.35 -22.95 168.35 -22.71Q167.35 -22.46 166.3 -22.27Q165.25 -22.07 164.07 -21.88Q161.78 -21.53 160.34 -20.73Q158.9 -19.92 158.21 -18.77Q157.53 -17.63 157.53 -16.21Q157.53 -13.92 159.12 -12.72Q160.71 -11.52 163.2 -11.52ZM194.94 0V-54.59H213.49V-44.14H214.08Q215.79 -49.27 219.94 -52.27Q224.09 -55.27 229.7 -55.27Q235.51 -55.27 239.66 -52.22Q243.81 -49.17 244.64 -44.14H245.23Q246.6 -49.17 251.11 -52.22Q255.63 -55.27 261.73 -55.27Q269.55 -55.27 274.43 -50.24Q279.31 -45.21 279.31 -36.82V0H259.68V-31.84Q259.68 -35.4 257.88 -37.43Q256.07 -39.45 253.04 -39.45Q250.02 -39.45 248.26 -37.43Q246.5 -35.4 246.5 -31.84V0H227.75V-31.84Q227.75 -35.4 225.94 -37.43Q224.14 -39.45 221.11 -39.45Q219.06 -39.45 217.59 -38.53Q216.13 -37.6 215.35 -35.91Q214.57 -34.23 214.57 -31.84V0Z"
}
