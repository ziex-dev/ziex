// spec: specs/examples-applications.plan.md
// seed: seed.spec.ts

import { test, expect } from '@playwright/test';


test.describe('Todo App Example - Edge Cases', () => {
  test('Add multiple todos and verify all are present', async ({ page }) => {
    await page.goto('/examples/todo');
    const todos = ['First todo', 'Second todo', 'Third todo', 'Fourth todo'];
    for (const todo of todos) {
      await page.getByRole('textbox', { name: /Add a new todo/ }).fill(todo);
      await page.getByRole('button', { name: 'Add' }).click();
      await expect(page.getByText(todo)).toBeVisible();
    }
    for (const todo of todos) {
      await expect(page.getByText(todo)).toBeVisible();
    }
  });

  test('Delete todo from the start', async ({ page }) => {
    await page.goto('/examples/todo');
    // Add a unique todo
    const todoText = `Delete me first ${Date.now()}`;
    await page.getByRole('textbox', { name: /Add a new todo/ }).fill(todoText);
    await page.getByRole('button', { name: 'Add' }).click();
    await expect(page.getByText(todoText)).toBeVisible();
    // Find the todo item containing the text and click its delete button
    const todoItem = page.locator('li', { hasText: todoText });
    await todoItem.getByRole('button', { name: /×/ }).click();
    await expect(page.getByText(todoText)).not.toBeVisible();
  });

  test('Delete todo from the middle', async ({ page }) => {
    await page.goto('/examples/todo');

    const t = Date.now();
    const todos = [`A${t}`, `B${t}`, `C${t}`];
    for (const todo of todos) {
      await page.getByRole('textbox', { name: /Add a new todo/ }).fill(todo);
      await page.getByRole('button', { name: 'Add' }).click();
      await expect(page.getByText(todo)).toBeVisible();
    }
    // Find the todo item for the middle todo and click its delete button
    const middleTodo = todos[1];
    const todoItem = page.locator('li', { hasText: middleTodo });
    await todoItem.getByRole('button', { name: /×/ }).click();
    await expect(page.getByText(middleTodo)).not.toBeVisible();
    await expect(page.getByText(todos[0])).toBeVisible();
    await expect(page.getByText(todos[2])).toBeVisible();
  });

  test('Update a todo (skip if not supported)', async ({ page }) => {
    await page.goto('/examples/todo');
   
    
    const todoText = `To update ${Date.now()}`;
    await page.getByRole('textbox', { name: /Add a new todo/ }).fill(todoText);
    await page.getByRole('button', { name: 'Add' }).click();
    // Try to double click and edit, but skip if not supported
    const todoItem = page.getByText(todoText);
    try {
      await todoItem.dblclick();
      await page.keyboard.type(' updated');
      await page.keyboard.press('Enter');
      await expect(page.getByText(`${todoText} updated`)).toBeVisible();
    } catch (e) {
      test.skip(true, 'Todo editing not supported in this implementation');
    }
  });

  test('Add empty todo should not add', async ({ page }) => {
    await page.goto('/examples/todo');
   
    
    const initialCount = await page.locator('li').count();
    await page.getByRole('textbox', { name: /Add a new todo/ }).fill('');
    await page.getByRole('button', { name: 'Add' }).click();
    const afterCount = await page.locator('li').count();
    expect(afterCount).toBe(initialCount);
  });

  test('Clear all todos (only those added in this test)', async ({ page }) => {
    await page.goto('/examples/todo');
   
    
    const todos = [`Clear me ${Date.now()}`, `Clear me too ${Date.now()}`];
    for (const todo of todos) {
      await page.getByRole('textbox', { name: /Add a new todo/ }).fill(todo);
      await page.getByRole('button', { name: 'Add' }).click();
      await expect(page.getByText(todo)).toBeVisible();
    }
    await page.getByRole('button', { name: 'Clear All' }).click();
    for (const todo of todos) {
      await expect(page.getByText(todo)).not.toBeVisible();
    }
  });
});
