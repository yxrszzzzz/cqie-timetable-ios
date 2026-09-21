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
    /// 自己写的备注也一起画上，预览才和首页一模一样
    let notes: [TimetableNote]
    let onCancel: () -> Void
    let onConfirm: (UIImage, Double) -> Void

    /// 当前屏幕的渲染倍率（iPhone 一般是 3）。
    /// 用它而不是 `UIScreen.main.scale`——后者在 iOS 16 之后不推荐，某些场景会返回 1，
    /// 那样烘出来的图只有实际像素的三分之一，一显示就糊
    @Environment(\.displayScale) private var displayScale

    /// 手势过程中在变化的值
    @State private var scale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var offset: CGSize = .zero
    /// 上一次手势结束时定下来的值，新一轮手势在它基础上叠加
    @State private var settledScale: CGFloat = 1
    @State private var settledRotation: Angle = .zero
    @State private var settledOffset: CGSize = .zero

    @State private var opacity: Double

    /// 取景框尺寸。
    ///
    /// 必须缓存下来，不能让手势依赖 `proxy.size`：拖动时每次 `@State` 变化都会让 body
    /// 重算，拿新的 size 重新构造手势，系统会把它当成另一个手势、把当前这次识别掐掉。
    /// 表现出来就是拖着拖着突然再也拖不动了。
    @State private var frameSize: CGSize = .zero

    init(
        source: UIImage,
        data: TimetableData,
        week: Int,
        chromeOpacity: Double,
        notes: [TimetableNote],
        initialOpacity: Double,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage, Double) -> Void
    ) {
        self.source = source
        self.data = data
        self.week = week
        self.chromeOpacity = chromeOpacity
        self.notes = notes
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _opacity = State(initialValue: initialOpacity)
    }

    var body: some View {
        // 取景框尺寸既用来预览、也用来烘焙，必须是同一个值
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                canvas(size: proxy.size, safeTop: proxy.safeAreaInsets.top)
                bottomBar(size: proxy.size)
            }
            .onAppear { frameSize = proxy.size }
            .onChange(of: proxy.size) { frameSize = $0 }
        }
        .ignoresSafeArea()
    }

    private func canvas(size: CGSize, safeTop: CGFloat) -> some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

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
            // 手势要留给底下那层拖动底图。
            //
            // 这里要让出顶部安全区：底图该铺满全屏，但课表得和首页一样从状态栏
            // 下面开始，否则表头会被刘海压住，摆位置时没法对齐
            TimetableGrid(
                data: data,
                week: week,
                onTapCourse: { _ in },
                onTapCollision: { _ in },
                hasBackground: true,
                chromeOpacity: chromeOpacity,
                notes: notes
            )
            .padding(.top, safeTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            // 把图片实际铺到的范围描出来。缩小或转过之后会有盖不满的地方，
            // 只对着课表摆是看不出来哪儿空着的
            outline(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        // 三条手势摊平并列，不要嵌套 SimultaneousGesture——嵌套写法在连续操作时
        // 很容易丢掉某一支，表现就是拖着拖着不动了
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
    }

    /// 描出底图实际占的位置。算法和 `bake` 是同一套，所以描出来的框就是存下来之后
    /// 图真正铺到的地方。
    private func outline(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            guard canvasSize.width > 0, canvasSize.height > 0 else { return }

            let cover = max(
                canvasSize.width / source.size.width,
                canvasSize.height / source.size.height
            )
            let halfWidth = source.size.width * cover * scale / 2
            let halfHeight = source.size.height * cover * scale / 2
            let centerX = canvasSize.width / 2 + offset.width
            let centerY = canvasSize.height / 2 + offset.height

            let radians = rotation.radians
            let cosA = cos(radians)
            let sinA = sin(radians)

            func corner(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
                CGPoint(
                    x: centerX + dx * cosA - dy * sinA,
                    y: centerY + dx * sinA + dy * cosA
                )
            }

            var path = Path()
            path.move(to: corner(-halfWidth, -halfHeight))
            path.addLine(to: corner(halfWidth, -halfHeight))
            path.addLine(to: corner(halfWidth, halfHeight))
            path.addLine(to: corner(-halfWidth, halfHeight))
            path.closeSubpath()

            context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 0.3), 6)
            }
            .onEnded { _ in settledScale = scale }
    }

    private var rotateGesture: some Gesture {
        RotationGesture()
            .onChanged { value in rotation = settledRotation + value }
            .onEnded { _ in settledRotation = rotation }
    }

    /// 位移要限个范围。两指旋转时这个手势也在跟第一根手指的位移，
    /// 边转边移很容易把图甩到屏幕外面去，看着就像「图片不见了」
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: clamp(
                        settledOffset.width + value.translation.width,
                        frameSize.width / 2
                    ),
                    height: clamp(
                        settledOffset.height + value.translation.height,
                        frameSize.height / 2
                    )
                )
            }
            .onEnded { _ in settledOffset = offset }
    }

    /// `limit <= 0`（尺寸还没量出来）时不限制
    private func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return value }
        return min(max(value, -limit), limit)
    }

    // MARK: - 控制条（半透明，压在预览之下）

    /// 半透明是有意的：底下的画面要一直看得见。
    /// 所有控件都压在底部——顶部坚决不放东西，表头「周一周二」就在最上面，
    /// 给它压一条横栏上去会直接挡住，摆位置时没法对齐
    private var barColor: Color {
        Color(.systemBackground).opacity(0.92)
    }

    private func bottomBar(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("旋转").font(.subheadline)
                Button {
                    turn(by: -90)
                } label: {
                    Image(systemName: "rotate.left").font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("向左转 90°")
                Button {
                    turn(by: 90)
                } label: {
                    Image(systemName: "rotate.right").font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("向右转 90°")
                Spacer()
                Button("复位") { reset() }
                    .buttonStyle(.bordered)
            }

            Text("底图不透明度 \(Int((opacity * 100).rounded()))%")
                .font(.subheadline)
            Slider(
                value: $opacity,
                in: TimetableBackground.minOpacity...TimetableBackground.maxOpacity
            )

            HStack(spacing: 12) {
                Text("单指拖动摆放")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                Button("确定") { confirm(size: size) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
                offset: offset,
                displayScale: displayScale
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
    offset: CGSize,
    displayScale: CGFloat
) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    // 关键：`frame` 的单位是「点」，format.scale 决定一个点画多少像素。
    // 用 1 的话烘出来的图只有屏幕实际像素的三分之一，一显示就被拉伸 3 倍，糊
    format.scale = max(displayScale, 1)
    format.opaque = true

    return UIGraphicsImageRenderer(size: frame, format: format).image { context in
        let cg = context.cgContext
        // 手机拍的原图动辄 4000~8000 像素宽，要压到屏幕这点像素（约 1200 宽），
        // 缩小倍数常常超过 3 倍。CG 默认的插值质量在这种倍数下是直接抽样的效果——
        // 细密的纹理（树叶、布纹、字）会糊成一片。编辑器里的预览走的是 SwiftUI 的
        // 高质量滤波，所以「预览清楚、存下来变糊」多半是栽在这儿
        cg.interpolationQuality = .high
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
