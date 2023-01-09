import re
from PyPDF2 import PdfReader

op_template_start = "pub const Op = struct {" + '\n'
op_template_end = '\n' + "};"

op_list = []
op_regex = r"((?P<Op>\w+)\s*=\s*[0-9]+\s*(?:\((?P<Hex>0x[0-9A-Fa-f]+)\)))+"
reader = PdfReader("scripts/opcodes.pdf")
for op_page in reader.pages:
    matches = re.findall(op_regex, op_page.extract_text())
    if not matches:
        continue

    for match in matches:
        _, op, hex = match
        op_str = f"    pub const {op.upper()}: u8 = {hex};"
        op_list.append(op_str)

op_zig = op_template_start
op_zig = op_zig + '\n'.join(op_list)
op_zig = op_zig + op_template_end

with open("src/op.zig", "w") as f:
    f.write(op_zig)