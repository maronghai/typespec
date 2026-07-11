# todo
id INTEGER ++
title TEXT * : Task title
done INTEGER * @ =0 : 0=pending, 1=done
created_at TEXT * =(datetime('now'))
