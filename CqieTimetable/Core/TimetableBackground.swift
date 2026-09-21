import UIKit

/// 课表底图。
///
/// 选中的图会压缩后存进 App 沙盒，而不是只记住相册里的那个标识——用户随时可能在
/// 相册里删掉原图或者在系统里关掉「照片」权限，那时候底图会变成一片空白，
/// 而且完全看不出为什么。
///
/// 另外底图只是「底」：上面会压一层系统背景色的蒙版（浓度 = 1 - [opacity]）。
/// 课程块本身是不透明的实色，不受影响；这层保的是节次、日期、表头这些细字。
enum TimetableBackground {

    /// 底图在最终画面里的可见程度。[1 - 这个值] 就是压在它上面的蒙版浓度
    static let defaultOpacity: Double = 0.20

    /// 最低也要留一点，否则等于没设底图
    static let minOpacity: Double = 0.05

    /// 允许调到完全可见。课程块本身是不透明的实色，节次栏和表头又各留了一层底，
    /// 所以调到满也还读得出课表
    static let maxOpacity: Double = 1.00

    private static let opacityKey = "cqie_background_opacity"

    static var opacity: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: opacityKey) as? Double
            return min(max(stored ?? defaultOpacity, minOpacity), maxOpacity)
        }
        set {
            UserDefaults.standard.set(
                min(max(newValue, minOpacity), maxOpacity),
                forKey: opacityKey
            )
        }
    }

    /// 压缩后的最长边。课表最多铺满一块屏幕，原图那几 MB 存着没意义
    private static let maxEdge: CGFloat = 1600

    private static let fileName = "timetable_background.jpg"

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent(fileName)
    }

    /// 当前的底图，没设置过返回 nil
    static func load() -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    /// 压缩后存进沙盒，失败返回 false
    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let data = resized(image).jpegData(compressionQuality: 0.88) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 按最长边等比缩小。原图直接存下来既占地方，解码时又吃内存
    private static func resized(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }

        let scale = maxEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
