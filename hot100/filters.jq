# portable walk/1 for jq < 1.6
def walk(f):
  def w:
    . as $in
    | if type == "object" then
        reduce keys[] as $k (.; .[$k] = (.[$k] | w))
      elif type == "array" then
        map( w )
      else .
      end;
  (w | f);

def cond_empty:
  walk(
    if type=="object" then
      (if has("if")   then .if   = {} else . end)
    | (if has("then") then .then = {} else . end)
    | (if has("else") then .else = {} else . end)
    else . end
  );

def strip_refs_inside_conditionals:
  walk(
    if type=="object" and (has("if") or has("then") or has("else")) then
      (if has("if")   then .if   |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    | (if has("then") then .then |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    | (if has("else") then .else |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    else . end
  );

def del_conditional_keys:
  walk(if type=="object" then del(.if, .then, .else) else . end);
