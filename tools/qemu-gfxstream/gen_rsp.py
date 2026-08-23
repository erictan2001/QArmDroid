"""gen_rsp.py: generate ninja rsp files for STATIC_LINKER_RSP / c_LINKER_RSP edges.

Parses build.ninja to find build edges whose rule uses a rspfile, computes the
rsp content, and writes <out>.rsp. Needed because our Python ninja driver does
not implement rspfile generation.
"""
import re, sys, os

def parse_edges(path):
    edges = {}  # out -> (rule, [inputs], )
    rules = {}  # rule -> dict of props
    cur_rule = None
    cur_rule_props = {}
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("rule "):
            cur_rule = ln[5:].strip()
            cur_rule_props = {}
        elif ln.startswith("build ") and ":" in ln:
            # build out: rule [inputs...]
            head = ln[len("build "):]
            out, rest = head.split(":", 1)
            parts = rest.split()
            rule = parts[0]
            inputs = [p for p in parts[1:] if not p.startswith("||") and p != "|" and p != "||"]
            # handle implicit deps after ||
            rule_props = dict(cur_rule_props) if rule == cur_rule else {}
            edges[out.strip()] = (rule, inputs, rule_props)
        elif ln.startswith("  ") and cur_rule:
            # rule property line like "  command = ...", "  rspfile = $out.rsp"
            m = re.match(r'\s+(\w+)\s*=\s*(.*)$', ln)
            if m:
                cur_rule_props[m.group(1)] = m.group(2)
        i += 1
    return edges

def main():
    build_ninja = sys.argv[1]
    workdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(build_ninja)
    edges = parse_edges(build_ninja)
    # Only edges whose rule has rspfile/rspfile_content
    for out, (rule, inputs, props) in edges.items():
        has_rsp = any(k.startswith("rspfile") for k in props)
        if not has_rsp:
            continue
        rsp_content = props.get("rspfile_content", "$in")
        # Compute rsp content. For STATIC_LINKER_RSP it is "$in" (newline).
        # For c_LINKER_RSP it is "$ARGS -o $out $in $LINK_ARGS".
        if rsp_content.strip() == "$in":
            content = "\n".join(inputs) + "\n"
        else:
            # reconstruct: replace $in with space-joined inputs, $out with out
            c = rsp_content
            c = c.replace("$out", out)
            c = c.replace("$in", " ".join(inputs))
            # leave $ARGS/$LINK_ARGS as-is; they're defined as rule-scope vars not
            # available here, so fall back to reading them from the rule command.
            content = c
        rsp_file = props.get("rspfile", "$out.rsp").replace("$out", out)
        rsp_path = os.path.join(workdir, rsp_file)
        with open(rsp_path, "w", encoding="utf-8", errors="replace") as f:
            f.write(content)
        print(f"wrote {rsp_path} ({len(content)} bytes)")

if __name__ == "__main__":
    main()
