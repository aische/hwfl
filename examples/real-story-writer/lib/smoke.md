---
name: lib/smoke
effects: [Exec, Write, Read, Net]
imports:
  - types/main
  - lib/kb
  - lib/util
  - lib/bible
---

## body

```hwfl
fun smoke_bible(): BibleOut =
  {
    title = "Ashport Compass",
    synopsis = "Mira arrives in Ashport with a salt-stained compass and must decide whether to trust the harbor master.",
    setting = "Ashport, a fogbound harbor town",
    entities = [
      { entity_id = "char:mira", kind = "Person", name = "Mira" },
      { entity_id = "char:harbor_master", kind = "Person", name = "Harbor Master Kell" },
      { entity_id = "place:ashport", kind = "Place", name = "Ashport" },
      { entity_id = "obj:compass", kind = "Object", name = "Salt Compass" }
    ],
    aliases = [
      { alias = "Mira", entity_id = "char:mira" },
      { alias = "Kell", entity_id = "char:harbor_master" },
      { alias = "Harbor Master", entity_id = "char:harbor_master" },
      { alias = "Ashport", entity_id = "place:ashport" },
      { alias = "Salt Compass", entity_id = "obj:compass" }
    ],
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira lived."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira stood on the Ashport quay."
      },
      {
        subject_id = "char:mira",
        pred = "has",
        object_entity_id = "obj:compass",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira kept the Salt Compass in her coat."
      },
      {
        subject_id = "obj:compass",
        pred = "bound_to",
        object_entity_id = "char:mira",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "The Salt Compass answered only to Mira."
      },
      {
        subject_id = "char:harbor_master",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Harbor Master Kell lived."
      },
      {
        subject_id = "char:harbor_master",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Kell kept office in Ashport."
      }
    ]
  }

fun smoke_outlines(): OutlinesOut =
  {
    chapters = [
      {
        chapter = 1,
        title = "Quay Fog",
        summary = "Mira arrives and meets Kell.",
        beats = ["Dock in fog", "Show the compass", "Kell warns her"],
        continuity_notes = "Mira alive at Ashport; she has the Salt Compass."
      },
      {
        chapter = 2,
        title = "Ledger Room",
        summary = "Kell tests whether Mira will surrender the compass.",
        beats = ["Argument in the ledger room", "Mira refuses", "She keeps watch"],
        continuity_notes = "Do not kill Mira; she remains in Ashport."
      },
      {
        chapter = 3,
        title = "North Pier",
        summary = "Mira and Kell form a wary alliance at the north pier.",
        beats = ["Shared watch", "Alliance", "Compass still hers"],
        continuity_notes = "Mira alive; allied_with Kell; still has compass."
      }
    ]
  }

fun smoke_ch1_delta(): AssertDelta =
  {
    entities = lib/util.empty_entities(()),
    aliases = lib/util.empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "knows",
        object_entity_id = "char:harbor_master",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira learned Harbor Master Kell's name."
      }
    ],
    source = { kind = "chapter", ref = "ch1", attempt = 1 }
  }

fun smoke_ch2_bad_delta(): AssertDelta =
  {
    entities = lib/util.empty_entities(()),
    aliases = lib/util.empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "dead",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira died on the ledger-room floor."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Dead Mira still paced Ashport's ledger room."
      }
    ],
    source = { kind = "chapter", ref = "ch2", attempt = 1 }
  }

fun smoke_ch2_good_delta(): AssertDelta =
  {
    entities = lib/util.empty_entities(()),
    aliases = lib/util.empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira lived through the argument."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira remained in Ashport's ledger room."
      },
      {
        subject_id = "char:mira",
        pred = "has",
        object_entity_id = "obj:compass",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira kept the Salt Compass."
      }
    ],
    source = { kind = "chapter", ref = "ch2", attempt = 2 }
  }

fun smoke_ch3_delta(): AssertDelta =
  {
    entities = lib/util.empty_entities(()),
    aliases = lib/util.empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "allied_with",
        object_entity_id = "char:harbor_master",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "Mira and Kell stood allied on the north pier."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "They kept watch over Ashport from the north pier."
      },
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "Mira lived."
      }
    ],
    source = { kind = "chapter", ref = "ch3", attempt = 1 }
  }

fun run_smoke(pid: String): Out =
  let _ = lib/kb.ensure_project(pid)
  let _ = fs.mkdir("story")
  let _ = fs.mkdir("outlines")
  let bible = smoke_bible()
  let bible_path = lib/bible.write_bible_md(bible, "story/bible.md")
  let seed = lib/bible.commit_or_repair_bible(pid, "", "", "", 3, bible)
  let outlines = smoke_outlines()
  let outlines_path = "outlines/chapters.md"
  let _ = fs.write(
    path = outlines_path,
    text = lib/util.format_outlines(outlines.chapters, 0, list.length(outlines.chapters))
  )
  let ch1_prose =
    "Fog pressed Ashport's quay into a narrow strip of wet boards. Mira stepped off the packet boat with the Salt Compass hard against her ribs. Harbor Master Kell met her with a lantern and a ledger under his arm. He said her name like a debt. She answered that the compass was hers, and that she intended to keep breathing in this town."
  let _ = fs.write(path = "story/ch1.md", text = ch1_prose)
  let c1 = lib/kb.assert_delta(pid, "commit", smoke_ch1_delta())
  let snap1 = lib/kb.write_snapshot(pid, "story/canon-after-ch1.md")
  let bad = lib/kb.assert_delta(pid, "dry_run", smoke_ch2_bad_delta())
  let findings_path = "story/ch2-findings.json"
  let _ = fs.write(path = findings_path, text = json.encode(bad))
  let ch2_bad_prose =
    "ERROR PATH: planted dead+located clash for Mira (not committed)."
  let _ = fs.write(path = "story/ch2-attempt1.md", text = ch2_bad_prose)
  let ch2_prose =
    "In the ledger room Kell asked for the Salt Compass as harbor bond. Mira refused without raising her voice. She lived through the argument, stayed in Ashport, and kept the compass buttoned in her coat while the fog tapped the windows."
  let _ = fs.write(path = "story/ch2.md", text = ch2_prose)
  let c2 =
    if bad.ok then
      {
        ok = false,
        committed = false,
        note = "planted contradiction was not caught"
      }
    else
      let good = lib/kb.assert_delta(pid, "commit", smoke_ch2_good_delta())
      {
        ok = good.ok && good.committed,
        committed = good.committed,
        note = "regen committed"
      }
  let ch3_prose =
    "By the north pier Mira and Kell shared a watch. They stood allied against the unlit water. Mira lived. Ashport held them both, and the Salt Compass still answered her hand."
  let _ = fs.write(path = "story/ch3.md", text = ch3_prose)
  let c3 = lib/kb.assert_delta(pid, "commit", smoke_ch3_delta())
  let snap_path = lib/kb.write_snapshot(pid, "story/canon.md")
  let caught = not(bad.ok)
  let committed_n =
    (if c1.ok && c1.committed then 1 else 0)
      + (if c2.committed then 1 else 0)
      + (if c3.ok && c3.committed then 1 else 0)
  let ok =
    seed.assert.ok
      && seed.assert.committed
      && c1.ok
      && c1.committed
      && c2.ok
      && c3.ok
      && c3.committed
      && caught
  let findings_json = json.encode(bad.findings)
  let report =
    if ok then
      $"smoke ok: contradiction caught ({findings_json}); committed {committed_n} chapters; snap1={snap1}"
    else
      $"smoke failed: seed.ok={seed.assert.ok} c1.ok={c1.ok} c2.ok={c2.ok} c3.ok={c3.ok} caught={caught} note={c2.note}"
  {
    ok = ok,
    project_id = pid,
    title = bible.title,
    chapters_requested = 3,
    chapters_committed = committed_n,
    contradiction_caught = caught,
    findings_path = findings_path,
    bible_path = bible_path,
    outlines_path = outlines_path,
    snapshot_path = snap_path,
    report = report
  }
```
