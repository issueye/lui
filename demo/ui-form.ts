/* M8-2 表单演示页：状态 + 校验提交（规则来自组件库的 UiRules） */

const plans = [
  { value: "basic", text: "基础版" },
  { value: "pro", text: "专业版" },
  { value: "team", text: "团队版" }
];

const form = reactive({
  name: "",
  mail: "",
  pwd: "",
  plan: "",
  level: 30,
  years: 5,
  agree: false
});

const state = reactive({ result: "—" });

function OnSubmit(): void {
  if (uiFormValidate("reg")) {
    state.result = "校验通过 ✓";
  } else {
    state.result = "有错误，请检查表单";
  }
}

function OnReset(): void {
  form.name = "";
  form.mail = "";
  form.pwd = "";
  form.plan = "";
  form.level = 30;
  form.years = 5;
  form.agree = false;
  state.result = "已重置";
}

onMount(function () {
  console.log("表单演示页就绪");
});
