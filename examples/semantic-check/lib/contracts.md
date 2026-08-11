---
name: lib/contracts
effects: [Read]
imports:
  - types/main
---

## body

```hwfl
fun empty_findings(_: Unit): List<Finding> = []

fun concat3(a: List<Finding>, b: List<Finding>, c: List<Finding>): List<Finding> =
  list.concat(a, list.concat(b, c))

fun concat4(a: List<Finding>, b: List<Finding>, c: List<Finding>, d: List<Finding>): List<Finding> =
  list.concat(concat3(a, b, c), d)

fun has_hwfl_fence(raw: String): Bool =
  text.contains(raw, "```hwfl")

fun is_bindable_slug(slug: String): Bool =
  slug == "system"
    || slug == "agent"
    || slug == "reviewer"
    || slug == "prompt"
    || slug == "user"
    || slug == "instructions"

fun has_effect_token(raw: String, eff: String): Bool =
  text.contains(raw, $"[{eff}]")
    || text.contains(raw, $"[{eff},")
    || text.contains(raw, $", {eff},")
    || text.contains(raw, $", {eff}]")

fun has_tools_list(raw: String): Bool =
  text.contains(raw, "tools =") || text.contains(raw, "tools=")

fun concat_sec_bodies(secs: List<{ slug: String, title: String, body: String }>, i: Int, n: Int): String =
  if i >= n then ""
  else $"{secs[i].body}\n{concat_sec_bodies(secs, i + 1, n)}"

fun dead_section_one(s: { slug: String, title: String, body: String }, raw: String, file: String): List<Finding> =
  if not(is_bindable_slug(s.slug)) then []
  else if text.metrics(s.body).chars < 40 then []
  else if not(has_hwfl_fence(raw)) then []
  else if text.contains(raw, $"@{s.slug}") then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Bindable section @{s.slug} is never interpolated",
      evidence = s.title,
      suggestion = $"Reference @{s.slug} from the hwfl fence, or rename the section to plain docs"
    }]

fun dead_section_findings(secs: List<{ slug: String, title: String, body: String }>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let here = dead_section_one(secs[i], raw, file)
    let used = list.length(here)
    list.concat(here, dead_section_findings(secs, raw, file, i + 1, n, remaining - used))

fun effect_gap_one(prose: String, raw: String, file: String, needle: String, eff: String): List<Finding> =
  if not(text.contains(prose, needle)) then []
  else if has_effect_token(raw, eff) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Prose names {needle} but effects lack {eff}",
      evidence = needle,
      suggestion = $"Add {eff} to frontmatter effects, or remove the prose claim"
    }]

fun tool_gap_one(prose: String, raw: String, file: String, needle: String, tool_expr: String): List<Finding> =
  if not(has_tools_list(raw)) then []
  else if not(text.contains(prose, needle)) then []
  else if text.contains(raw, tool_expr) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Prose names {needle} but tools list lacks {tool_expr}",
      evidence = needle,
      suggestion = $"Add {tool_expr} to tools, or remove the prose claim"
    }]

fun effect_tool_gaps(prose: String, raw: String, file: String): List<Finding> =
  if not(has_hwfl_fence(raw)) then empty_findings(())
  else
    concat4(
      list.concat(
        effect_gap_one(prose, raw, file, "exec.run", "Exec"),
        effect_gap_one(prose, raw, file, "exec_run", "Exec")
      ),
      list.concat(
        effect_gap_one(prose, raw, file, "fs.write", "Write"),
        list.concat(
          effect_gap_one(prose, raw, file, "fs_write", "Write"),
          list.concat(
            effect_gap_one(prose, raw, file, "fs.patch", "Write"),
            effect_gap_one(prose, raw, file, "fs_patch", "Write")
          )
        )
      ),
      list.concat(
        effect_gap_one(prose, raw, file, "llm.chat", "Net"),
        list.concat(
          effect_gap_one(prose, raw, file, "llm.object", "Net"),
          effect_gap_one(prose, raw, file, "llm.agent", "Net")
        )
      ),
      list.concat(
        tool_gap_one(prose, raw, file, "exec.run", "tool(exec.run)"),
        list.concat(
          tool_gap_one(prose, raw, file, "exec_run", "tool(exec.run)"),
          list.concat(
            tool_gap_one(prose, raw, file, "fs.write", "tool(fs.write)"),
            list.concat(
              tool_gap_one(prose, raw, file, "fs_write", "tool(fs.write)"),
              list.concat(
                tool_gap_one(prose, raw, file, "fs.patch", "tool(fs.patch)"),
                tool_gap_one(prose, raw, file, "fs_patch", "tool(fs.patch)")
              )
            )
          )
        )
      )
    )

fun is_schema_section(title: String): Bool =
  text.contains(title, "schema") || text.contains(title, "Schema")

fun is_type_name(s: String): Bool =
  s == "String"
    || s == "Bool"
    || s == "Int"
    || s == "Float"
    || s == "List"
    || s == "FileRef"
    || s == "Unit"
    || s == "Json"

fun has_output_field(raw: String, field: String): Bool =
  text.contains(raw, $"{field}: String")
    || text.contains(raw, $"{field}: Bool")
    || text.contains(raw, $"{field}: Int")
    || text.contains(raw, $"{field}: Float")
    || text.contains(raw, $"{field}: List")
    || text.contains(raw, $"{field}: FileRef")
    || text.contains(raw, $"{field}: Unit")
    || text.contains(raw, $"{field}: Json")

fun field_label_token(tok: String): String =
  if not(text.contains(tok, ":")) then ""
  else
    let name = text.normalize_token(tok)
    if name == "" then ""
    else if is_type_name(name) then ""
    else if text.contains(name, "/") then ""
    else if text.contains(name, ".") then ""
    else if text.metrics(name).chars < 2 then ""
    else if text.metrics(name).chars > 32 then ""
    else name

fun output_gap_from_words(words: List<String>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let name = field_label_token(words[i])
    let rest = output_gap_from_words(words, raw, file, i + 1, n, remaining)
    if name == "" then rest
    else if has_output_field(raw, name) then rest
    else if not(text.contains(raw, "outputs:")) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "contract",
          file = file,
          claim = $"Schema prose promises field absent from outputs: {name}",
          evidence = name,
          suggestion = $"Add {name} to frontmatter outputs, or drop it from the schema section"
        }],
        output_gap_from_words(words, raw, file, i + 1, n, remaining - 1)
      )

fun output_gap_sections(secs: List<{ slug: String, title: String, body: String }>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let s = secs[i]
    let here =
      if not(is_schema_section(s.title)) then empty_findings(())
      else
        let words = text.words(s.body)
        output_gap_from_words(words, raw, file, 0, list.length(words), remaining)
    let used = list.length(here)
    list.concat(here, output_gap_sections(secs, raw, file, i + 1, n, remaining - used))

fun recommends_exec(body: String): Bool =
  text.contains(body, "exec.run") || text.contains(body, "exec_run")

fun skill_exec_quote(body: String): String =
  if text.contains(body, "exec.run") then "exec.run"
  else if text.contains(body, "exec_run") then "exec_run"
  else "exec"

fun path_to_qname(path_s: String): String =
  text.strip_suffix(path_s, ".md")

fun collect_skill_exec_hints(paths: List<FileRef>, i: Int, n: Int): List<SkillExecHint> =
  if i >= n then []
  else
    let p = paths[i]
    let path_s = $"{p}"
    let rest = collect_skill_exec_hints(paths, i + 1, n)
    if not(text.starts_with(path_s, "skills/")) then rest
    else
      let contents = fs.read(p)
      if not(recommends_exec(contents.text)) then rest
      else
        list.concat(
          [{
            id = path_to_qname(path_s),
            file = path_s,
            quote = skill_exec_quote(contents.text)
          }],
          rest
        )

fun skill_caller_gap_one(hint: SkillExecHint, prose: String, raw: String, file: String): List<Finding> =
  if has_effect_token(raw, "Exec") then []
  else if not(text.contains(prose, hint.id)) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Caller lacks Exec but references skill that recommends {hint.quote}",
      evidence = $"skill={hint.id} quote={hint.quote}",
      suggestion = "Add Exec to caller effects, or stop naming that skill from this module"
    }]

fun skill_caller_gaps_hints(hints: List<SkillExecHint>, prose: String, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let here = skill_caller_gap_one(hints[i], prose, raw, file)
    let used = list.length(here)
    list.concat(here, skill_caller_gaps_hints(hints, prose, raw, file, i + 1, n, remaining - used))

fun contract_file(path: FileRef, hints: List<SkillExecHint>, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else
    let contents = fs.read(path)
    let raw = contents.text
    let path_s = $"{path}"
    let secs = md.sections(raw)
    let prose = concat_sec_bodies(secs, 0, list.length(secs))
    let dead = dead_section_findings(secs, raw, path_s, 0, list.length(secs), remaining)
    let rem1 = remaining - list.length(dead)
    let gaps = effect_tool_gaps(prose, raw, path_s)
    let rem2 = rem1 - list.length(gaps)
    let outs = output_gap_sections(secs, raw, path_s, 0, list.length(secs), rem2)
    let rem3 = rem2 - list.length(outs)
    let cross =
      if text.starts_with(path_s, "workflows/") then
        skill_caller_gaps_hints(hints, prose, raw, path_s, 0, list.length(hints), rem3)
      else empty_findings(())
    concat4(dead, gaps, outs, cross)

fun contracts_all(paths: List<FileRef>, hints: List<SkillExecHint>, i: Int, n: Int, remaining: Int): List<Finding> =
  if i >= n || remaining <= 0 then []
  else
    let here = contract_file(paths[i], hints, remaining)
    let used = list.length(here)
    list.concat(here, contracts_all(paths, hints, i + 1, n, remaining - used))
```
