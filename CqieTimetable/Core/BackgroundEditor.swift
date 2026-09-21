import SwiftUI
import UIKit

/// 底图编辑器：拖拽平移、双指缩放、双指旋转，再调一下不透明度。
///
/// 这里的变换语义和 `bake` 里烘焙时用的是同一套——都围绕取景框中心，
/// 顺序都是「先缩放到铺满 → 再缩放 → 旋转 → 平移」——所以预览所见即成品所得。
struct BackgroundEditor: View {

    let source: UIImage
    /// 叠在底图上的课表示意要用它
    let data: TimetableData
    let week: Int
    let onCancel: () -> Void
    let onConfirm: (UIImage, Double) -> Void

    /// 手势过程中在变化的值
    @State private var scale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    /// 上一次手势结束时定下来的值，新一轮手势在它基础上叠加
    @State private var settledScale: CGFloat = 1
    @State private var settledRotation: Angle = .zero
    @State private var settledOffset: CGSize = .zero

    @State private var opacity: Double

    init(
        source: UIImage,
        data: TimetableData,
        week: Int,
        initialOpacity: Double,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage, Double) -> Void
    ) {
        self.source = source
        self.data = data
        self.week = week
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _opacity = State(initialValue: initialOpacity)
    }

    var body: some View {
        NavigationStack {
            // 取景框尺寸既用来预览、也用来烘焙，必须是同一个值，所以从这里往上提
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    canvas(size: proxy.size)
                    controls(size: proxy.size)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") { confirm(size: proxy.size) }
                    }
                }
            }
            .navigationTitle("调整底图")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func canvas(size: CGSize) -> some View {
        ZStack {
            Color.black
            Image(uiImage: source)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .rotationEffect(rotation)
                .offset(offset)

            // 虚化的课表示意：一眼看出课程块会落在图片的哪一块，
            // 又不至于把底图本身挡住。手势要留给底下那层，所以关掉命中。
            TimetableSketch(data: data, week: week)
                .frame(width: size.width, height: size.height)
                .blur(radius: 6)
                .opacity(0.55)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(combinedGesture)
    }

    private var combinedGesture: some Gesture {
        SimultaneousGesture(
            SimultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(settledScale * value, 0.3), 6)
                    }
                    .onEnded { _ in settledScale = scale },
                RotationGesture()
                    .onChanged { value in rotation = settledRotation + value }
                    .onEnded { _ in settledRotation = rotation }
            ),
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: settledOffset.width + value.translation.width,
                        height: settledOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in settledOffset = offset }
        )
    }

    private func controls(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("旋转").font(.caption)
                Button {
                    turn(by: -90)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .accessibilityLabel("向左转 90°")
                Button {
                    turn(by: 90)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .accessibilityLabel("向右转 90°")
                Spacer()
                Button("复位") { reset() }
            }
            .font(.caption)
            .buttonStyle(.borderless)

            Text("底图不透明度 \(Int((opacity * 100).rounded()))%")
                .font(.caption)
            Slider(
                value: $opacity,
                in: TimetableBackground.minOpacity...TimetableBackground.maxOpacity
            )
            Text("调高底图更清楚，但课表的节次、日期这些细字也越难读。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func turn(by degrees: Double) {
        rotation += .degrees(degrees)
        settledRotation = rotation
    }

    private func reset() {
        scale = 1
        settledScale = 1
        rotation = .zero
        settledRotation = .zero
        offset = .zero
        settledOffset = .zero
    }

    private func confirm(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onConfirm(
            bake(
                source: source,
                frame: size,
                scale: scale,
                rotation: rotation,
                offset: offset
            ),
            opacity
        )
    }
}

/// 把预览里的变换烘焙成一张固定尺寸的图。
///
/// CG 的变换是「后调用的先作用于点」，所以下面这四行的实际效果是：
/// 围绕取景框中心缩放、旋转，再整体平移。预览那边 `.scaleEffect` / `.rotationEffect`
/// 也是围绕视图中心、`.offset` 就是平移，两边对得上。
///
/// 缩放里乘了个 cover：预览用的是 `scaledToFill`，图先要铺满取景框，用户再在其上缩放。
private func bake(
    source: UIImage,
    frame: CGSize,
    scale: CGFloat,
    rotation: Angle,
    offset: CGSize
) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: frame, format: format).image { context in
        let cg = context.cgContext
        cg.setFillColor(UIColor.black.cgColor)
        cg.fill(CGRect(origin: .zero, size: frame))

        let cover = max(frame.width / source.size.width, frame.height / source.size.height)
        let fitted = CGSize(
            width: source.size.width * cover,
            height: source.size.height * cover
        )
        let rect = CGRect(
            x: (frame.width - fitted.width) / 2,
            y: (frame.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )

        cg.translateBy(
            x: frame.width / 2 + offset.width,
            y: frame.height / 2 + offset.height
        )
        cg.rotate(by: rotation.radians)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -frame.width / 2, y: -frame.height / 2)

        source.draw(in: rect)
    }
}

/// 课表的粗略示意：只画节次栏和课程色块，不画文字。
/// 夹在底图和用户之间做参考，所以刻意做得很淡。
private struct TimetableSketch: View {

    let data: TimetableData
    let week: Int

    private let gutterWidth: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            ForEach(1...max(data.visibleSectionCount, 1), id: \.self) { section in
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth)
                    ForEach(1...7, id: \.self) { day in
                        cell(day: day, section: section)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func cell(day: Int, section: Int) -> some View {
        let courses = data.coursesAt(week: week, weekDay: day, section: section)
        return ZStack {
            if let first = courses.first {
                RoundedRectangle(cornerRadius: 4).fill(color(for: first.name))
            }
        }
        .padding(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for name: String) -> Color {
        Color(hue: CoursePalette.hue(for: name), saturation: 0.45, brightness: 0.85)
    }
}
