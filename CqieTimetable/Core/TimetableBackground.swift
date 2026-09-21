import UIKit

/// 课表底图。
///
/// 选中的图会压缩后存进 App 沙盒，而不是只记住相册里的那个标识——用户随时可能在
/// 相册里删掉原图或者在系统里关掉「照片」权限，那时候底图会变成一片空白，
/// 而且完全看不出为什么。
///
/// 另外底图只是「底」：上面会压一层系统背景色的蒙版（见 [scrimOpacity]）。
/// 课程块本身是不透明的实色，不受影响；这层保的是节次、日期、表头这些细字。
enum TimetableBackground {

    /// 铺在底图之上的背景色不透明度。
    ///
    /// 这个值直接决定「课还能不能看清」：底图最暗是纯黑时，浅色外观下底约 #CCCCCC；
    /// 最亮是纯白时，深色外观下约 #333333。两种极端下正文与次要文字都有足够对比度。
    /// 调低会让底图更清楚，但也更容易把节次、日期这些细字压掉。
    static let scrimOpacity: Double = 0.80

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
