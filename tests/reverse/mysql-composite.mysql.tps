# `tags`
id int ++ *
name s64 * @u

# `article_tag`
article_id int *
tag_id int *

> article_id articles.id
> tag_id tags.id