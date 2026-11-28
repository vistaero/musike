import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import { ownLifetime } from "../backend/lifecycle.mjs";

test("fragmented shutdown commands close once, including subsequent EOF", async () => {
  const input = new PassThrough();
  let closed = 0;
  ownLifetime(input, () => closed++);
  input.write("shut");
  assert.equal(closed, 0);
  input.write("down\nshutdown\n");
  input.end();
  await new Promise(resolve => input.on("end", resolve));
  assert.equal(closed, 1);
});
test("a crashed native host closes the sidecar through EOF", async () => {
  const input = new PassThrough();
  let closed = 0;
  ownLifetime(input, () => closed++);
  input.end();
  await new Promise(resolve => input.on("end", resolve));
  assert.equal(closed, 1);
});
test("unrelated input is ignored and unbounded input is rejected", () => {
  const input = new PassThrough();
  let closed = 0;
  ownLifetime(input, () => closed++);
  input.write("hello\n");
  assert.equal(closed, 0);
  input.write("x".repeat(4097));
  assert.equal(closed, 1);
  input.destroy();
});
