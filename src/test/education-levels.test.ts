import { describe, it, expect } from "vitest";
import { amountForLevel, appliesToLevel, subjectsForClasses, teachingPairs } from "@/lib/education-levels";

const classes = [
  { name: "BASIC 1", levelCode: "primary" },
  { name: "JHS 1", levelCode: "junior-secondary" },
];
const subjects = [
  { name: "MATHEMATICS", levelCode: "primary" },
  { name: "ICT", levelCode: "junior-secondary" },
];

describe("education levels", () => {
  it("offers only subjects of the chosen classes' levels", () => {
    expect(subjectsForClasses(classes, subjects, ["JHS 1"])).toEqual(["ICT"]);
  });
  it("pairs a subject only with classes at its level", () => {
    const r = teachingPairs(classes, subjects, ["BASIC 1", "JHS 1"], ["MATHEMATICS", "ICT"]);
    expect(r.pairs).toEqual([
      { class_name: "BASIC 1", subject: "MATHEMATICS" },
      { class_name: "JHS 1", subject: "ICT" },
    ]);
    expect(r.unmatched).toEqual([]);
  });
  it("reports a subject not offered at any chosen class level", () => {
    expect(teachingPairs(classes, subjects, ["JHS 1"], ["MATHEMATICS"]).unmatched).toEqual(["MATHEMATICS"]);
  });
  it("a charge limited to some levels does not apply elsewhere", () => {
    expect(appliesToLevel({ levels: "junior-secondary" }, "primary")).toBe(false);
    expect(appliesToLevel({ levels: "" }, "primary")).toBe(true);
  });
  it("uses the per-level amount when set", () => {
    expect(amountForLevel({ amount: "100", "amount:primary": "80" }, "primary")).toBe(80);
    expect(amountForLevel({ amount: "100" }, "primary")).toBe(100);
  });
});
