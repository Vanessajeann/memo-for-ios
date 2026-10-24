import SwiftUI

enum MemoStyle {
    static let blue = Color(red:0.196,green:0.435,blue:0.965)
    static let red = Color(red:1,green:0.275,blue:0.357)
}
struct MemoBackground:View {
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        ZStack {
            (scheme == .dark ? Color(red:0.045,green:0.065,blue:0.105) : Color(red:0.945,green:0.961,blue:0.991))
            GeometryReader { g in
                Circle().fill(MemoStyle.blue.opacity(scheme == .dark ? 0.17 : 0.13)).frame(width:g.size.width*0.9).blur(radius:65).offset(x:-g.size.width*0.35,y:-80)
                Circle().fill(Color.cyan.opacity(scheme == .dark ? 0.10 : 0.09)).frame(width:g.size.width*0.85).blur(radius:70).offset(x:g.size.width*0.4,y:g.size.height*0.3)
                Circle().fill(Color.purple.opacity(0.07)).frame(width:g.size.width*0.8).blur(radius:70).offset(x:-60,y:g.size.height*0.7)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
extension View {
    func glassCard(radius:CGFloat = 24)->some View {
        background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))
            .overlay(RoundedRectangle(cornerRadius:radius).stroke(.white.opacity(0.30),lineWidth:1).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius:radius))
    }
    func memoPage()->some View { background(Color.clear).scrollContentBackground(.hidden).toolbarBackground(.hidden,for:.navigationBar).background { MemoBackground() } }
}
