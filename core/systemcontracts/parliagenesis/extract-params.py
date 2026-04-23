#!/usr/bin/env python3
"""Extract default parameter values from a generate.py abchain_* function.

Usage: extract-params.py <generate.py path> <command-name>
       command-name uses hyphens: abchain-local, abchain-main, abchain-test

Writes shell-sourceable KEY=VALUE pairs to stdout.
"""
import ast
import re
import sys

# Parameters to extract → shell variable name written to params.env
PARAMS = {
    "init_num_of_cabinets":     "EXPECTED_INIT_NUM_OF_CABINETS",
    "init_burn_ratio":          "EXPECTED_BURN_RATIO",
    "init_system_reward_ratio": "EXPECTED_SYS_REWARD_RATIO",
    "foundation_addr":          "EXPECTED_FOUNDATION",
}


def solidity_addr_to_hex(s):
    """Convert 'address(0xdEaD)' or '0x<40hex>' to a zero-padded hex address."""
    s = s.strip()
    m = re.fullmatch(r"address\(0x([0-9a-fA-F]+)\)", s)
    if m:
        return "0x" + m.group(1).zfill(40)
    if re.fullmatch(r"0x[0-9a-fA-F]{40}", s, re.IGNORECASE):
        return s
    return None


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <generate.py> <command-name>", file=sys.stderr)
        sys.exit(1)

    generate_py, cmd = sys.argv[1], sys.argv[2]
    func_name = cmd.replace("-", "_")

    with open(generate_py) as fh:
        tree = ast.parse(fh.read(), filename=generate_py)

    func = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            func = node
            break

    if func is None:
        print(f"error: function '{func_name}' not found in {generate_py}", file=sys.stderr)
        sys.exit(1)

    args = func.args.args
    defaults = func.args.defaults
    offset = len(args) - len(defaults)

    found = {}
    for i, default in enumerate(defaults):
        arg_name = args[offset + i].arg
        if arg_name in PARAMS:
            found[arg_name] = ast.literal_eval(default)

    for param, env_var in PARAMS.items():
        if param not in found:
            print(f"error: parameter '{param}' not found in '{func_name}'", file=sys.stderr)
            sys.exit(1)
        raw = str(found[param])
        if param == "foundation_addr":
            addr = solidity_addr_to_hex(raw)
            if addr is None:
                print(f"error: cannot parse foundation_addr value: {raw!r}", file=sys.stderr)
                sys.exit(1)
            print(f"{env_var}={addr}")
        else:
            print(f"{env_var}={int(raw)}")


if __name__ == "__main__":
    main()
