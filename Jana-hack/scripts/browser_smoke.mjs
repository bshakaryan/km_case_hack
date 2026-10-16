/** Run against a running local stack with demo seed; this creates one demo request.
 * Install optional runner: npm install --prefix frontend --no-save --package-lock=false playwright
 * Then: npx --prefix frontend playwright install chromium
 * Run from root: node scripts/browser_smoke.mjs
 * PLAYWRIGHT_PACKAGE may point to an already installed Playwright package.
 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PACKAGE || "../frontend/node_modules/playwright");
const origin = process.env.WEB_URL || "http://127.0.0.1:3000";
const env = readFileSync(resolve(".env"), "utf8");
const password = process.env.DEMO_PASSWORD || env.match(/^DEMO_PASSWORD=(.+)$/m)?.[1]?.trim();
assert.ok(password, "Set DEMO_PASSWORD or generate local .env");
const output = resolve("frontend/.qa/browser-smoke");
mkdirSync(output, { recursive: true });
const browser = await chromium.launch({ headless: true, ...(process.env.BROWSER_EXECUTABLE ? { executablePath: process.env.BROWSER_EXECUTABLE } : {}) });
const errors = [];
const serverErrors = [];
let lastPage;

async function login(page, actor) {
  await page.getByLabel("Рабочая почта").fill(`${actor}@example.com`);
  await page.getByLabel("Пароль", { exact: true }).fill(password);
  const auth = page.waitForResponse(r => r.url().endsWith("/api/auth/login"));
  await page.getByRole("button", { name: "Войти в JanaМен" }).click();
  await page.getByRole("heading", { name: /Сәлем,/ }).waitFor();
  return (await (await auth).json()).access_token;
}
async function logout(page) {
  await page.getByRole("button", { name: "Выйти из аккаунта" }).click();
  await page.getByRole("heading", { name: "Добро пожаловать" }).waitFor();
}
async function tab(page, name) {
  await page.getByRole("navigation").getByRole("button", { name: new RegExp("^" + name) }).click();
}
function watch(page) {
  lastPage = page;
  page.on("pageerror", error => errors.push(error.message));
  page.on("response", response => { if (response.status() >= 500) serverErrors.push(`${response.status()} ${response.url()}`); });
}

try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  watch(page);
  await page.goto(origin);
  await page.screenshot({ path: `${output}/login-desktop.png`, fullPage: true });
  const employeeToken = await login(page, "employee");
  const employeeHeaders = { Authorization: `Bearer ${employeeToken}` };
  const initialProfile = await (await context.request.get(`${origin}/api/me`, { headers: employeeHeaders })).json();
  const existing = await (await context.request.get(`${origin}/api/requests`, { headers: employeeHeaders })).json();
  const occupied = existing.filter(item => item.status !== "rejected");
  let start = "2027-03-20", end = "2027-03-25";
  if (initialProfile.leave_balance < 3 || occupied.some(item => item.start_date <= end && item.end_date >= start)) {
    start = end = Array.from({ length: 300 }, (_, i) => new Date(Date.UTC(2027, 3, 1 + i)).toISOString().slice(0, 10))
      .find(day => !["05-01", "05-07", "05-09", "07-06", "08-30", "10-25", "12-16"].includes(day.slice(5)) && !occupied.some(item => item.start_date <= day && day <= item.end_date));
    assert.ok(start && initialProfile.leave_balance > 0, "No free leave days for smoke");
  }
  await page.getByRole("button", { name: "Создать заявку", exact: true }).waitFor();
  await page.getByRole("heading", { name: "Знакомство с JanaМен", exact: true }).waitFor();
  await page.screenshot({ path: `${output}/dashboard-desktop.png`, fullPage: true });
  await tab(page, "Мой профиль");
  await page.getByText("Арман Демо", { exact: true }).waitFor();
  await tab(page, "Главная");
  await page.getByRole("button", { name: "Создать заявку", exact: true }).click();
  const form = page.getByRole("dialog", { name: "Заявка на отпуск", exact: true });
  await form.getByLabel("Дата начала").fill(start);
  await form.getByLabel("Дата окончания").fill(end);
  await form.getByText(/По расчёту mock 1С:ЗУП:/).waitFor();
  await page.screenshot({ path: `${output}/zup-calculation.png`, fullPage: true });
  await form.getByLabel(/Комментарий/).fill("Браузерная проверка сквозного сценария");
  const creation = page.waitForResponse(r => r.url().endsWith("/api/requests") && r.request().method() === "POST");
  await form.getByRole("button", { name: "Отправить заявку" }).click();
  const response = await creation;
  assert.equal(response.status(), 201);
  const request = await response.json();
  assert.equal(request.days_count, start === "2027-03-20" ? 3 : 1);
  if (start === "2027-03-20") assert.deepEqual(request.excluded_dates, ["2027-03-21", "2027-03-22", "2027-03-23"]);
  const detail = page.getByRole("dialog", { name: `Заявка №${request.id}`, exact: true });
  await detail.getByText("История заявки", { exact: true }).waitFor();
  assert.equal(await detail.getByText("Подтвердить решение", { exact: true }).count(), 0);
  await detail.getByRole("button", { name: "Закрыть", exact: true }).click();

  await tab(page, "Jana Academy");
  await page.getByRole("button", { name: /^(Начать обучение|Продолжить|Повторить материал)$/ }).click();
  const course = page.getByRole("dialog", { name: "Jana Academy · Обучение" });
  await course.getByRole("heading", { name: "Знакомство с JanaМен" }).waitFor();
  if (!(await course.getByRole("heading", { name: "Курс завершён" }).count())) {
    const read = course.getByRole("button", { name: "Материал изучен — перейти к тесту" });
    if (await read.count()) await read.click();
    await course.getByLabel("Только позвонить курьеру").check();
    await course.getByRole("button", { name: "Отправить ответ" }).click();
    await course.getByRole("alert").filter({ hasText: "Ответ неверный" }).waitFor();
    await course.getByLabel("В карточке заявки и уведомлениях").check();
    await course.getByRole("button", { name: "Отправить ответ" }).click();
    await course.getByRole("heading", { name: "Курс завершён" }).waitFor();
  }
  await course.getByRole("button", { name: "Закрыть", exact: true }).click();
  await tab(page, "HR-помощник");
  await page.getByRole("button", { name: "Как подать заявку на отпуск?", exact: true }).click();
  await page.getByRole("button", { name: /Как подать заявку на отпуск Заявки/ }).click();
  const source = page.getByRole("dialog", { name: "Источник ответа" });
  await source.getByRole("heading", { name: "Как подать заявку на отпуск" }).waitFor();
  await source.getByRole("button", { name: "Закрыть", exact: true }).click();
  await page.getByLabel("Ваш вопрос").fill("Какая погода на Марсе?");
  await page.getByRole("button", { name: "Отправить вопрос" }).click();
  await page.getByText(/В демонстрационной базе нет надёжного ответа/).waitFor();

  await logout(page);
  await login(page, "manager");
  await tab(page, "Заявки");
  await page.getByRole("button", { name: "Заявки команды", exact: true }).click();
  await page.getByRole("row").filter({ hasText: `№${request.id} ·` }).getByRole("button", { name: "Рассмотреть" }).click();
  const review = page.getByRole("dialog", { name: `Заявка №${request.id}`, exact: true });
  await review.getByLabel("Комментарий к решению").fill("Проверено руководителем в браузере");
  const decision = page.waitForResponse(r => r.url().endsWith(`/api/requests/${request.id}/status`) && r.request().method() === "PATCH");
  await review.getByRole("button", { name: "Подтвердить решение" }).click();
  assert.equal((await decision).status(), 200);
  await review.getByText("Руководитель согласовал заявку", { exact: true }).waitFor();
  await review.getByText("На проверке HR", { exact: true }).waitFor();
  await page.screenshot({ path: `${output}/request-manager-approved.png`, fullPage: true });
  await review.getByRole("button", { name: "Закрыть", exact: true }).click();

  await logout(page);
  await login(page, "hr");
  await tab(page, "Заявки");
  await page.getByRole("button", { name: "Заявки команды", exact: true }).click();
  await page.getByRole("row").filter({ hasText: `№${request.id} ·` }).getByRole("button", { name: "Рассмотреть" }).click();
  const hrReview = page.getByRole("dialog", { name: `Заявка №${request.id}`, exact: true });
  await hrReview.getByText("Финальное решение HR", { exact: true }).waitFor();
  await hrReview.getByLabel("Комментарий к решению").fill("Финально проверено HR в браузере");
  const hrDecision = page.waitForResponse(r => r.url().endsWith(`/api/requests/${request.id}/status`) && r.request().method() === "PATCH");
  await hrReview.getByRole("button", { name: "Подтвердить решение" }).click();
  assert.equal((await hrDecision).status(), 200);
  await hrReview.getByText("HR согласовал заявку", { exact: true }).waitFor();
  await hrReview.getByText(/Передано в mock 1С:ЗУП/).waitFor();
  await page.screenshot({ path: `${output}/request-approved.png`, fullPage: true });
  await hrReview.getByRole("button", { name: "Закрыть", exact: true }).click();
  await tab(page, "Журнал аудита");
  await page.getByText("request.manager_approved", { exact: true }).first().waitFor();
  await page.getByText("request.approved", { exact: true }).first().waitFor();
  await page.getByText("zup.leave_registered", { exact: true }).first().waitFor();
  await tab(page, "Команда");
  await page.getByRole("heading", { name: "Интеграция 1С:ЗУП" }).waitFor();
  await page.getByText(/Mock 1С:ЗУП подключён по HTTP/).waitFor();
  await page.screenshot({ path: `${output}/zup-integration.png`, fullPage: true });
  await logout(page);
  await login(page, "employee");
  await tab(page, "Мой профиль");
  await page.getByText(`${initialProfile.leave_balance - request.days_count} дней отпуска`, { exact: true }).waitFor();
  await tab(page, "Уведомления");
  const notification = page.getByRole("article").filter({ hasText: `Заявка №${request.id}:` });
  await notification.getByRole("heading", { name: "Заявка одобрена" }).waitFor();
  const read = page.waitForResponse(r => r.url().endsWith("/read") && r.request().method() === "PATCH");
  await notification.getByRole("button", { name: "Прочитано" }).click();
  assert.equal((await read).status(), 200);
  await logout(page);
  await login(page, "outsider");
  assert.equal(await page.getByRole("navigation").getByRole("button", { name: "Команда", exact: true }).count(), 0);
  await tab(page, "Заявки");
  assert.equal(await page.getByRole("row").filter({ hasText: `№${request.id} ·` }).count(), 0);
  await tab(page, "Главная");
  await page.reload();
  await page.getByRole("heading", { name: "Добро пожаловать" }).waitFor();

  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const small = await mobile.newPage();
  watch(small);
  await small.goto(origin);
  await small.screenshot({ path: `${output}/login-mobile.png`, fullPage: true });
  await login(small, "employee");
  await small.getByRole("button", { name: "Создать заявку", exact: true }).waitFor();
  await small.getByRole("heading", { name: "Знакомство с JanaМен", exact: true }).waitFor();
  await small.screenshot({ path: `${output}/dashboard-mobile.png`, fullPage: true });
  assert.ok(await small.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "Mobile page overflows horizontally");
  await small.getByRole("button", { name: "Открыть меню" }).click();
  await tab(small, "Мой профиль");
  await small.getByRole("heading", { name: "Мой профиль", exact: true }).waitFor();
  await small.getByText("Арман Демо", { exact: true }).waitFor();
  assert.deepEqual(errors, [], "Browser JavaScript errors");
  assert.deepEqual(serverErrors, [], "HTTP server errors");
  console.log(`Browser smoke passed: request ${request.id}, employee → manager → HR → employee, Academy, sources/refusal, session reset, mobile 390px. Screenshots: ${output}`);
} catch (error) {
  await lastPage?.screenshot({ path: `${output}/failure.png`, fullPage: true }).catch(() => {});
  throw error;
} finally {
  await browser.close();
}
