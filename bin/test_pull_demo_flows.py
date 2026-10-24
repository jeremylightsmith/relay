#!/usr/bin/env python3
"""Unit tests for bin/pull_demo_flows.py, the writer behind `prod pull-demo-flows`.

Run: python3 bin/test_pull_demo_flows.py
"""
import copy
import importlib.util
import json
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
TEMPLATES = HERE.parent / "docs" / "designs" / "templates"

spec = importlib.util.spec_from_file_location("pull_demo_flows", HERE / "pull_demo_flows.py")
pdf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdf)


def parts(text):
    doc = json.loads(text)
    return {k: doc[k] for k in pdf.PARTS}


def sorted_keys(value):
    """`value` with every object's keys in alphabetical order — how Jason encodes an Elixir map."""
    if isinstance(value, dict):
        return {k: sorted_keys(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [sorted_keys(v) for v in value]
    return value


class MergeTest(unittest.TestCase):
    def test_writing_a_files_own_parts_back_changes_nothing(self):
        for path in sorted(TEMPLATES.glob("*.json")):
            text = path.read_text()
            with self.subTest(path.name):
                self.assertEqual(pdf.merge(text, sorted_keys(parts(text))), text)

    def test_replaces_stages_and_flows_and_keeps_the_rest(self):
        text = (TEMPLATES / "three-brain.json").read_text()
        new = parts(text)
        new["stages"][1]["wip_limit"] = 9
        new["flows"] = new["flows"][:1]

        merged = json.loads(pdf.merge(text, new))

        self.assertEqual({k: merged[k] for k in pdf.PARTS}, new)
        before = json.loads(text)
        self.assertNotIn("agents", pdf.PARTS)
        for key in before.keys() - set(pdf.PARTS):
            self.assertEqual(merged[key], before[key])

    def test_a_new_node_puts_key_and_type_first_and_run_last(self):
        text = (TEMPLATES / "bare-minimum.json").read_text()
        new = parts(text)
        new["flows"][0]["nodes"].append({"run": "go", "writes": ["tasks"], "type": "agent", "key": "extra"})

        merged = pdf.merge(text, new)

        lines = merged[merged.index('"key": "extra"'):].splitlines()[:4]
        self.assertEqual([line.strip().split(":")[0] for line in lines], ['"key"', '"type"', '"writes"', '"run"'])

    def test_a_key_added_to_an_existing_node_goes_before_run(self):
        text = (TEMPLATES / "bare-minimum.json").read_text()
        new = sorted_keys(parts(text))
        new["flows"][0]["nodes"][0]["llm"] = "Claude Opus"

        merged = json.loads(pdf.merge(text, new))

        self.assertEqual(list(merged["flows"][0]["nodes"][0])[-2:], ["llm", "run"])

    def test_an_edited_node_keeps_its_existing_key_order(self):
        text = (TEMPLATES / "bare-minimum.json").read_text()
        new = parts(text)
        node = new["flows"][0]["nodes"][0]
        before = list(node)
        new["flows"][0]["nodes"][0] = dict(sorted(copy.deepcopy(node).items()))

        merged = json.loads(pdf.merge(text, new))  # json keeps key order

        self.assertEqual(list(merged["flows"][0]["nodes"][0]), before)


if __name__ == "__main__":
    unittest.main()
