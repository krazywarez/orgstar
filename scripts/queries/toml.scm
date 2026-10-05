; TOML highlights for Orgstar: table names as types, keys as properties. The grammar's own
; query captures whole pairs as properties, which colors values too.
(comment) @comment
(string) @string
(quoted_key) @string
[(integer) (float)] @number
(boolean) @constant
[(offset_date_time) (local_date_time) (local_date) (local_time)] @string.special
(table (bare_key) @type)
(table (dotted_key (bare_key) @type))
(table_array_element (bare_key) @type)
(table_array_element (dotted_key (bare_key) @type))
(pair (bare_key) @property)
(pair (dotted_key (bare_key) @property))
"=" @operator
