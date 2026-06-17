#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW New - Scaffold generator for composite ADW workflow scripts

Usage: uv run adws/adw_new.py <workflow-name> --steps plan,build,review [options]

Arguments:
  <workflow-name>   short name for the new workflow (e.g. "plan-build-test")
                    Output file: adw_<name-with-underscores>_iso.py

Options:
  --steps STEPS     comma-separated ordered list of steps to chain
                    Valid steps: plan patch build test review document ship
  --local           generate a "_local_iso" variant (no GitHub issue required)
  --dry-run         print the generated script to stdout, don't write to disk
  --output PATH     override the output file path
  --overwrite       overwrite if the output file already exists
"""

import argparse
import os
import sys

VALID_STEPS = ["plan", "patch", "build", "test", "review", "document", "ship"]


def make_script(name: str, steps: list[str], local: bool) -> str:
    suffix = "_local_iso" if local else "_iso"
    script_name = f"adw_{name}{suffix}.py"
    step_suffix = "_local_iso" if local else "_iso"

    # Build docstring step list
    doc_steps = "\n".join(
        f"{i + 1}. adw_{step}{step_suffix}.py - {step.title()} phase"
        for i, step in enumerate(steps)
    )

    # Build usage hint lines
    usage_lines = "\n".join(
        f'        print("  {i + 1}. {step.title()}")'
        for i, step in enumerate(steps)
    )

    # Build step blocks
    step_blocks = []
    for step in steps:
        var = step.replace("-", "_")
        cmd_var = f"{var}_cmd"
        result_var = var
        phase_label = f"ISOLATED {step.upper()} PHASE"
        fail_msg = f"Isolated {step} phase failed"
        sub_script = f"adw_{step}{step_suffix}.py"

        block = f"""    {cmd_var} = [
        "uv",
        "run",
        os.path.join(script_dir, "{sub_script}"),
        issue_number,
        adw_id,
    ]
    print(f"\\n=== {phase_label} ===")
    print(f"Running: {{' '.join({cmd_var})}}")
    {result_var} = subprocess.run({cmd_var})
    if {result_var}.returncode != 0:
        print("{fail_msg}")
        sys.exit(1)"""
        step_blocks.append(block)

    steps_block = "\n\n".join(step_blocks)

    # Build description for docstring
    step_names = " + ".join(s.title() for s in steps)
    iso_label = "local isolated" if local else "isolated"

    # Split the PEP 723 marker so uv doesn't treat it as a second metadata block
    pep723_open = "# ///" + " script"
    pep723_close = "# ///"

    return f"""#!/usr/bin/env -S uv run
{pep723_open}
# dependencies = ["python-dotenv", "pydantic"]
{pep723_close}

\"\"\"
ADW {name.replace("_", " ").title()} Iso - Compositional workflow for {iso_label} {step_names.lower()}

Usage: uv run {script_name} <issue-number> [adw-id]

This script runs:
{doc_steps}

The scripts are chained together via persistent state (adw_state.json).
\"\"\"

import subprocess
import sys
import os

# Add the parent directory to Python path to import modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adw_modules.workflow_ops import ensure_adw_id


def main():
    \"\"\"Main entry point.\"\"\"
    if len(sys.argv) < 2:
        print("Usage: uv run {script_name} <issue-number> [adw-id]")
        print("\\nThis runs the {iso_label} {step_names.lower()} workflow:")
{usage_lines}
        sys.exit(1)

    issue_number = sys.argv[1]
    adw_id = sys.argv[2] if len(sys.argv) > 2 else None

    # Ensure ADW ID exists with initialized state
    adw_id = ensure_adw_id(issue_number, adw_id)
    print(f"Using ADW ID: {{adw_id}}")

    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))

{steps_block}

    print(f"\\n=== ISOLATED WORKFLOW COMPLETED ===")
    print(f"ADW ID: {{adw_id}}")
    print(f"All phases completed successfully!")


if __name__ == "__main__":
    main()
"""


def main():
    parser = argparse.ArgumentParser(
        description="Scaffold a composite ADW workflow script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Valid steps: " + ", ".join(VALID_STEPS),
    )
    parser.add_argument("workflow_name", help="short name for the workflow (e.g. plan-build-test)")
    parser.add_argument(
        "--steps",
        required=True,
        help="comma-separated ordered list of steps (e.g. plan,build,test)",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="generate a _local_iso variant (no GitHub issue required)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the generated script to stdout, don't write to disk",
    )
    parser.add_argument("--output", help="override the output file path")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="overwrite if the output file already exists",
    )

    args = parser.parse_args()

    # Normalize name: dashes → underscores
    name = args.workflow_name.replace("-", "_")

    # Validate steps
    raw_steps = [s.strip() for s in args.steps.split(",") if s.strip()]
    if not raw_steps:
        print("Error: --steps must include at least one step", file=sys.stderr)
        sys.exit(1)

    invalid = [s for s in raw_steps if s not in VALID_STEPS]
    if invalid:
        print(f"Error: invalid step(s): {', '.join(invalid)}", file=sys.stderr)
        print(f"Valid steps: {', '.join(VALID_STEPS)}", file=sys.stderr)
        sys.exit(1)

    # Generate script content
    content = make_script(name, raw_steps, args.local)

    if args.dry_run:
        print(content)
        return

    # Determine output path
    if args.output:
        out_path = args.output
    else:
        suffix = "_local_iso" if args.local else "_iso"
        script_dir = os.path.dirname(os.path.abspath(__file__))
        out_path = os.path.join(script_dir, f"adw_{name}{suffix}.py")

    if os.path.exists(out_path) and not args.overwrite:
        print(f"Error: {out_path} already exists. Use --overwrite to replace it.", file=sys.stderr)
        sys.exit(1)

    with open(out_path, "w") as f:
        f.write(content)

    os.chmod(out_path, 0o755)

    suffix = "_local_iso" if args.local else "_iso"
    run_name = f"adw_{name}{suffix}.py"
    print(f"Created: {out_path}")
    print(f"Run with: uv run {out_path} <issue-number>")


if __name__ == "__main__":
    main()
