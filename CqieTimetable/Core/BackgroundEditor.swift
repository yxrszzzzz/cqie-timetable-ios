import SwiftUI
import UIKit

/// 底图编辑器：拖拽平移、双指缩放、双指旋转，再调一下不透明度。
///
/// 取景框就是整屏，里面按**最终效果**摆好底图、蒙版和真实的课表——所以看到的就是首页的样子，
/// 不用靠几个色块去想象。控制条半透明压在上下两边，不挡预览。
///
/// 变换语义和 `bake` 里烘焙用的是同一套（都围绕取景框中心），所以预览所见即成品所得。
struct BackgroundEditor: View {

    let source: UIImage
    let data: TimetableData
    let week: Int
    let chromeOpacity: Double
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
        chromeOpacity: Double,
        initialOpacity: Double,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage, Double) -> Void
    ) {
        self.source = source
        self.data = data
        self.week = week
        self.chromeOpacity = chromeOpacity
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _opacity = State(initialValue: initialOpacity)
    }

    var body: some View {
        // 取景框尺寸既用来预览、也用来烘焙，必须是同一个值
        GeometryReader { proxy in
            ZStack {
                canvas(size: proxy.size)
                VStack {
                    topBar(size: proxy.size)
                    Spacer()
                    bottomBar
                }
            }
        }
        .ignoresSafeArea()
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

            // 和首页同一层蒙版，所见即所得
            Color(.systemBackground).opacity(1 - opacity)

            // 真实课表。编辑期间它只是给人看的，所以不接任何操作——
            // 手势要留给底下那层拖动底图
            TimetableGrid(
                data: data,
                week: week,
                onTapCourse: { _ in },
                onTapCollision: { _ in },
                hasBackground: true,
                chromeOpacity: chromeOpacity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - 控制条（半透明，压在预览之上）

    private var barColor: Color {
        Color(.systemBackground).opacity(0.92)
    }

    private func topBar(size: CGSize) -> some View {
        HStack {
            Button("取消", action: onCancel)
            Spacer()
            Text("拖动摆放底图")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("确定") { confirm(size: size) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(barColor)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(barColor)
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
