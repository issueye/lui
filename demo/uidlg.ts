/* lui M8-3 反馈与浮层演示页逻辑 */

const state = reactive({
  dialogVisible: false,
  drawerVisible: false,
  statusText: "就绪",
  count: 0,
  loading: false
});

function OpenDialog(): void {
  state.dialogVisible = true;
  state.statusText = "已打开对话框";
}

function OnDialogOk(): void {
  state.dialogVisible = false;
  state.statusText = "对话框已提交并确认";
  uiMessage.success("对话框确认成功");
}

function OnDialogClose(): void {
  state.dialogVisible = false;
  state.statusText = "对话框已取消/关闭";
}

function OpenDrawer(): void {
  state.drawerVisible = true;
  state.statusText = "已打开抽屉面板";
}

function OnDrawerClose(): void {
  state.drawerVisible = false;
  state.statusText = "抽屉已关闭";
}

function ShowMsgInfo(): void {
  uiMessage.info("普通提示信息");
}

function ShowMsgSuccess(): void {
  uiMessage.success("操作已成功完成！");
}

function ShowMsgWarning(): void {
  uiMessage.warning("请注意数据安全！");
}

function ShowMsgError(): void {
  uiMessage.error("网络连接出现异常！");
}

function TriggerConfirm(): void {
  state.statusText = "等待确认操作...";
  uiMessageBox.confirm("操作确认", "确定执行清空缓存操作？").then(function (ok) {
    if (ok) {
      state.statusText = "确认操作已生效 ✓";
      uiMessage.success("清理完成");
    } else {
      state.statusText = "用户取消了操作 ✕";
      uiMessage.info("操作已取消");
    }
  });
}

function TriggerAlert(): void {
  uiMessageBox.alert("系统公告", "服务将于今晚 24:00 进行例行升级维护。");
}

function ToggleLoading(): void {
  state.loading = !state.loading;
}

onMount(function () {
  console.log("反馈与浮层演示页加载完成");
});
