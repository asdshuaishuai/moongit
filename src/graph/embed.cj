// embed.cj —— 图谱产物的「嵌入模式」引导脚本（热力图与架构图两份产物共用）。
//
// 放在图谱层而不是 Dendro：架构图渲染器（archhtml.cj）也在用，而图谱层不认识 Dendro。
// 各产物自己的嵌入样式表仍在各自旁边（indexEmbedCss 在 Dendro 的 treehtml.cj、archEmbedCss 在 archhtml.cj）。

package cambium.graph

import cambium.util.*


// MARK: - 嵌入模式（宿主页面内嵌）

/// 嵌入契约：宿主在产物**任何脚本之前**（<head> 最前面）注入
///   window.CAMBIUM_EMBED = { chrome: "page", vars: { "--bg": "#…", … }, canvas: { bg: "#…", … } }
/// · chrome === "page"：收拢外壳（宿主已有页头与状态条）、换宿主主题；不注入或别的值 = 独立完整版，逐字节同旧。
/// · vars：CSS 自定义属性，由下面的引导脚本写到 <html> 与 <body> 的内联样式上。
/// · canvas：画在 canvas 上的颜色与圆角（驱动 JS 经 cv(key, 原值) 读取）。
///
/// 引导脚本放在 <body> 开头：那时 body 已存在，内联变量才盖得过 `body.dark { --bg: … }` 这类
/// 写在类选择器上的变量（架构图产物就是这么定义的）；也早于第一帧绘制，不会先闪一下独立版外壳。
public func embedBootstrapJs(): String {
    return "(function(){var e=window.CAMBIUM_EMBED||window.MOONGIT_EMBED;if(!e||e.chrome!=='page'){return;}" +
        "document.documentElement.setAttribute('data-embed','page');" +
        "var v=e.vars||{};for(var k in v){if(Object.prototype.hasOwnProperty.call(v,k)){" +
        "document.documentElement.style.setProperty(k,String(v[k]));" +
        "document.body.style.setProperty(k,String(v[k]));}}})();"
}

public func embedBootstrapTag(): String {
    return "<script>" + embedBootstrapJs() + "\n</script>\n"
}
