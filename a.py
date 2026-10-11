import re

files = [
    "fs/read_write.c",
    "fs/open.c",
    "fs/stat.c",
    "fs/exec.c",
    "drivers/input/input.c",
]

pattern = re.compile(
    r'[ \t]*#ifdef CONFIG_KSU.*?#endif[ \t]*\n',
    re.DOTALL
)

for f in files:
    with open(f, 'r', encoding='utf-8', errors='surrogateescape') as fh:
        src = fh.read()
    new, n = pattern.subn('', src)
    if n:
        with open(f, 'w', encoding='utf-8', errors='surrogateescape') as fh:
            fh.write(new)
    print(f"{f}: removed {n} block(s)")