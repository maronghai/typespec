; SQLite: template inheritance
$ demo

% base
id   n++
ts   t

#base post
title   s *
content S

#base comment
text S *
post_id n *
