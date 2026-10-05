import { describe, expect, it } from "vitest";
import { whereOf } from "../src/where";

describe("whereOf", () => {
  it("an instance origin", () => {
    expect(whereOf("https://alice.skein.nexus/amm/mandala/tokens/")).toEqual({ base: "https://alice.skein.nexus", app: "amm", page: "tokens" });
  });
  it("a host's dev form, /@<handle>", () => {
    expect(whereOf("http://127.0.0.1:8100/@alice/amm/mandala/deploy/index.html")).toEqual({ base: "http://127.0.0.1:8100/@alice", app: "amm", page: "deploy" });
  });
  it("any app name, the Mandala app's own included", () => {
    expect(whereOf("http://a.localhost:8100/mandala/mandala/tokens")?.app).toBe("mandala");
    expect(whereOf("http://a.localhost:8100/my-amm/mandala/deploy/")?.app).toBe("my-amm");
  });
  it("no app, no page", () => {
    expect(whereOf("http://a.localhost:8100/mandala/tokens/")).toBeUndefined();
    expect(whereOf("http://a.localhost:8100/amm/mandala/other/")).toBeUndefined();
    expect(whereOf("http://a.localhost:8100/")).toBeUndefined();
  });
});
