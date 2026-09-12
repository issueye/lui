/* lui 组件库入口：页面用 <script src="../ui/index.ts"/> 引入；样式需宿主加载 ui/theme/lui-light.css
   （深色主题再叠加 lui-dark.css）。
   TS 子集没有模块系统，用 ui.include（相对当前脚本目录、同一文件只执行一次）拼接分件。 */

ui.include("components/basic.ts");
ui.include("components/button.ts");
ui.include("components/input.ts");

console.log("lui ui 组件库已加载（" + ui.version + "）");
