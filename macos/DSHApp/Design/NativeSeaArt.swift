import SwiftUI

/// 品牌图形的唯一来源：白昼浅湖 + 跃身鲸。
///
/// 三处共用这份文件——悬浮圈（FloatingBubble.swift）、转录尾部的运行指示器
/// （ConversationView.swift 的 WaveIconArt）、以及 App 图标。图标生成器
/// （scripts/generate-app-icon.swift）不在 app target 里、用的是 AppKit
/// 绘制，没法 import 这里，所以它是**手抄一份**：改这里的常量时必须同步改
/// 那边，否则 Dock 里的图标会和界面里的对不上。
///
/// 决策记录见 .agents/notes/implemented/feature/2026-08-27-bubble-whale-daylight.md。
enum SeaArt {
  // MARK: 配色 —— 果冻海的浅色一档
  //
  // 水必须是**真半透明**：果冻的"深"是层与层叠出来的，不是刷上去的。
  // 底层曾用 0.92 不透明的深青，被否为"不像果冻海、不够清澈"。这三个
  // alpha 是硬约束，别往上调。参照 DSHTheme.canvas 自身就浅到 0.961。
  static let skyTop = Color(red: 1.0, green: 1.0, blue: 0.996)
  static let skyBottom = Color(red: 0.945, green: 0.980, blue: 0.976)
  static let waterFar = Color(red: 0.62, green: 0.96, blue: 0.93)
  static let waterMid = Color(red: 0.45, green: 0.92, blue: 0.88)
  static let waterNear = Color(red: 0.22, green: 0.82, blue: 0.78)
  static let waterFarAlpha = 0.34
  static let waterMidAlpha = 0.42
  static let waterNearAlpha = 0.52
  /// 鲸是画面里唯一的深色——焦点唯一，这是"干净"的来源。
  static let whaleInk = Color(red: 0.055, green: 0.235, blue: 0.255)
  /// 圆的外轮廓线：极淡的暗色，保证浅色圆压在浅色背景上也分得开。
  static let rimShade = Color(red: 0.04, green: 0.30, blue: 0.28)

  static var sky: LinearGradient {
    LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)
  }

  // MARK: 构图 —— 全部以 44pt 画布为基准
  /// 鲸所占的方框边长。26pt 时鲸横跨近六成直径，把海景压没了（用户反馈
  /// "太大了，比例不对"）；19pt 留出天和水，圈才读成一片海。
  static let whaleSize: CGFloat = 19
  /// 最低点（lift = 0）时鲸的纵向偏移，正值向下。
  static let whaleRestY: CGFloat = 7.5
  /// 跃身的纵向行程。
  static let whaleTravel: CGFloat = 13.0

  // MARK: 动画时序
  /// 一次跃身的周期。
  static let breachPeriod: Double = 5.5
  /// 起浪：开始运行时海水涨上来。
  static let tideRise: Double = 0.7
  /// 退浪：运行结束时海水退去。退得比涨得慢一点，收尾才不显得仓促。
  static let tideFall: Double = 0.9

  /// 三次缓入缓出，给潮位过渡用。
  static func easeInOut(_ p: Double) -> CGFloat {
    let c = min(max(p, 0), 1)
    return CGFloat(c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2)
  }

  /// 跃身的三个量都写成周期的连续函数，首尾自然衔接——早期原型用
  /// `-3 + 6c` 这种线性漂移，每圈末尾会闪一下。
  /// - Returns: (抬升 0…1，翻转角，水平漂移)，后两者以 44pt 画布为基准。
  static func breach(at time: Double) -> (lift: CGFloat, tilt: Double, dx: CGFloat) {
    let c = (time / breachPeriod).truncatingRemainder(dividingBy: 1)
    let phase = c * .pi * 2
    // 角度只跟垂直速度走：上升抬头 / 顶点放平 / 下落低头。把角度接在
    // lift 上是错的——那样顶点仍然是抬头的，看着像后仰。
    return (CGFloat(0.5 - 0.5 * cos(phase)), -22.0 * sin(phase), CGFloat(-2.5 * cos(phase)))
  }
}

/// 跃身鲸 —— 原创图形，与任何第三方标识无关。
///
/// 构造方式是「圆心链」：给若干站点 (x, y, 半径)，Catmull-Rom 插值出中轴线
/// 与粗细，再沿法线偏移成轮廓，头尾用整圆封口。头因此一定是钝圆的，这正是
/// "鲸"和"鱼"的分界；手调贝塞尔控制点做不到这一点（试过三轮，出来的是
/// 蝌蚪和鱼）。坐标在 100×100 方框内，y 向下，头朝右上。
struct WhaleBody: Shape {
  /// 头 → 尾。半径决定粗细，所以头部那两站最粗。
  static let stations: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
    (78, 38, 22), (58, 42, 22), (38, 50, 15), (25, 58, 7), (17, 63, 3),
  ]
  /// 中轴线采样密度。1024pt 的图标下采样过疏会露出棱边。
  var samples = 120

  func path(in rect: CGRect) -> Path {
    let k = min(rect.width, rect.height) / 100
    func project(_ p: CGPoint) -> CGPoint {
      CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k)
    }
    let spine = Self.spine(samples: samples)
    guard spine.count > 1 else { return Path() }

    var upper: [CGPoint] = [], lower: [CGPoint] = []
    upper.reserveCapacity(spine.count)
    lower.reserveCapacity(spine.count)
    for i in spine.indices {
      let before = spine[max(i - 1, 0)].center
      let after = spine[min(i + 1, spine.count - 1)].center
      var vx = after.x - before.x, vy = after.y - before.y
      let length = max(sqrt(vx * vx + vy * vy), 0.0001)
      vx /= length; vy /= length
      let nx = -vy, ny = vx
      let c = spine[i].center, r = spine[i].radius
      upper.append(CGPoint(x: c.x + nx * r, y: c.y + ny * r))
      lower.append(CGPoint(x: c.x - nx * r, y: c.y - ny * r))
    }

    var path = Path()
    let head = spine[0]
    let headAngle = atan2(head.center.y - spine[1].center.y, head.center.x - spine[1].center.x)
    path.move(to: project(upper[0]))
    path.addArc(center: project(head.center), radius: head.radius * k,
                startAngle: .radians(headAngle - .pi / 2),
                endAngle: .radians(headAngle + .pi / 2), clockwise: false)
    for p in lower.dropFirst() { path.addLine(to: project(p)) }
    let tail = spine[spine.count - 1]
    let tailAngle = atan2(tail.center.y - spine[spine.count - 2].center.y,
                          tail.center.x - spine[spine.count - 2].center.x)
    path.addArc(center: project(tail.center), radius: tail.radius * k,
                startAngle: .radians(tailAngle + .pi / 2),
                endAngle: .radians(tailAngle - .pi / 2), clockwise: false)
    for p in upper.reversed().dropFirst() { path.addLine(to: project(p)) }
    path.closeSubpath()
    return path
  }

  /// Catmull-Rom 插值出的中轴线：每个采样点带一个半径。
  private static func spine(samples: Int) -> [(center: CGPoint, radius: CGFloat)] {
    func interpolate(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat, _ t: CGFloat) -> CGFloat {
      let t2 = t * t, t3 = t2 * t
      return 0.5 * ((2 * p1) + (-p0 + p2) * t
        + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
    let s = stations
    guard s.count >= 2 else { return [] }
    let perSegment = max(samples / (s.count - 1), 2)
    var out: [(CGPoint, CGFloat)] = []
    for segment in 0..<(s.count - 1) {
      let i0 = max(segment - 1, 0), i1 = segment
      let i2 = segment + 1, i3 = min(segment + 2, s.count - 1)
      for step in 0...perSegment {
        if segment > 0 && step == 0 { continue }
        let t = CGFloat(step) / CGFloat(perSegment)
        let x = interpolate(s[i0].x, s[i1].x, s[i2].x, s[i3].x, t)
        let y = interpolate(s[i0].y, s[i1].y, s[i2].y, s[i3].y, t)
        let r = interpolate(s[i0].r, s[i1].r, s[i2].r, s[i3].r, t)
        out.append((CGPoint(x: x, y: y), max(r, 0.3)))
      }
    }
    return out.map { (center: $0.0, radius: $0.1) }
  }
}

/// 尾鳍：以尾柄末端为根，两片后掠的叶。span 23 是调出来的——再窄就读成
/// 鱼尾，再宽会盖住身体。
struct WhaleFluke: Shape {
  var root = CGPoint(x: 17, y: 63)
  var angle: CGFloat = 2.55
  var span: CGFloat = 23
  var length: CGFloat = 21

  func path(in rect: CGRect) -> Path {
    let k = min(rect.width, rect.height) / 100
    let ux = cos(angle), uy = sin(angle)      // 指向尾后
    let nx = -uy, ny = ux
    func q(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + (root.x + ux * along + nx * across) * k,
              y: rect.minY + (root.y + uy * along + ny * across) * k)
    }
    var path = Path()
    path.move(to: q(-2, 3))
    path.addQuadCurve(to: q(length, span), control: q(length * 0.35, span * 0.85))
    path.addQuadCurve(to: q(length * 0.42, 2), control: q(length * 0.85, span * 0.30))
    path.addQuadCurve(to: q(length * 0.98, -span), control: q(length * 0.80, -span * 0.32))
    path.addQuadCurve(to: q(-2, -3), control: q(length * 0.32, -span * 0.85))
    path.closeSubpath()
    return path
  }
}

/// 口线：画成天空色的一道细弧。这是让剪影读成"鲸"而不是"鱼"的关键一笔，
/// 去掉之后小尺寸下只剩一个深色团块。
struct WhaleMouth: Shape {
  func path(in rect: CGRect) -> Path {
    let k = min(rect.width, rect.height) / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * k, y: rect.minY + y * k)
    }
    var path = Path()
    path.move(to: p(96, 44))
    path.addQuadCurve(to: p(70, 54), control: p(83, 52))
    path.addQuadCurve(to: p(96, 44), control: p(83, 54.6))
    path.closeSubpath()
    return path
  }
}

/// 完整的鲸：身体 + 尾鳍 + 口线 + 眼。画在一个正方形里，自带 100×100 的
/// 内部坐标，所以任何尺寸下比例一致。
struct WhaleMark: View {
  var ink: Color = SeaArt.whaleInk
  var cutout: Color = SeaArt.skyTop
  var samples = 120

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      ZStack {
        WhaleBody(samples: samples).fill(ink)
        WhaleFluke().fill(ink)
        WhaleMouth().fill(cutout)
        // 眼：44pt 下只有 1.2pt，但没有它小尺寸会退化成一团深色。
        Circle().fill(cutout)
          .frame(width: side * 0.052, height: side * 0.052)
          .position(x: side * 0.82, y: side * 0.37)
      }
      .frame(width: side, height: side)
    }
  }
}

/// 圈里的一帧海景：天空 → 远浪 → 鲸 → 中浪 → 近浪。
/// 鲸夹在远浪和中浪之间，所以跃身最低点会被前两层水盖住背，读作"半沉"。
///
/// `level` 是**潮位**，也是这颗圈的状态本身：
///   0 —— 空闲。没有海浪，只有一只鲸静静浮在白底上。
///   1 —— 运行中。满潮，鲸在跃身。
/// 中间值就是起浪/退浪的过渡帧。把"在不在跑"编码成有没有水，比之前靠
/// 降饱和 + 动不动去区分要直接得多——一眼就够，不用盯着看。
struct SeaWhaleScene: View {
  /// 波形相位（秒）。静止时传一个固定值即可。
  var wavePhase: Double
  /// 跃身进度用的时间（秒）。
  var breachTime: Double
  /// 潮位 0…1，见上。
  var level: CGFloat = 1
  var side: CGFloat = 44

  var body: some View {
    let k = side / 44
    let t = wavePhase
    let m = SeaArt.breach(at: breachTime)
    // 退潮时基线整体下沉出圈并淡出；fade 乘 1.6 让水在潮位很低时就先隐去，
    // 免得留下一条贴着圆底的细边。
    let sink = (1 - level) * 0.55
    let fade = Double(min(level * 1.6, 1))
    // 鲸的动作幅度也跟着潮位收：没有水的时候它不跃身，静静居中。
    let lift = m.lift * level
    let tilt = Double(m.tilt) * Double(level)
    let dx = m.dx * level
    let restY = SeaArt.whaleRestY * level
    ZStack {
      SeaArt.sky
      WaveBand(baseY: 0.60 + sink, amplitude: 0.075, phase: t * 1.6)
        .fill(SeaArt.waterFar.opacity(SeaArt.waterFarAlpha * fade))
      WhaleMark()
        .frame(width: SeaArt.whaleSize * k, height: SeaArt.whaleSize * k)
        .rotationEffect(.degrees(tilt))
        .offset(x: dx * k, y: (restY - SeaArt.whaleTravel * lift) * k)
        .frame(width: side, height: side)
      WaveBand(baseY: 0.70 + sink, amplitude: 0.065, phase: t * 2.2 + 2.1)
        .fill(SeaArt.waterMid.opacity(SeaArt.waterMidAlpha * fade))
      WaveBand(baseY: 0.80 + sink, amplitude: 0.055, phase: t * 2.9 + 4.4)
        .fill(SeaArt.waterNear.opacity(SeaArt.waterNearAlpha * fade))
    }
    .frame(width: side, height: side)
  }
}
