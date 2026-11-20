import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const css = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');

test('interactive action buttons share one visible brand colour on white surfaces', () => {
  assert.match(css, /--action-button:#f28c28/);
  assert.match(css, /--action-button-hover:#df7616/);
  assert.match(css, /button:not\(\.tabbar button\):not\(\.group button\)/);
  assert.match(css, /color:var\(--action-button-text\)/);
  assert.match(css, /:focus-visible/);
});
