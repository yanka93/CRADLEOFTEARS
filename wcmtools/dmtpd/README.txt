This is a server to inject mail into Sendmail/Postfix/etc's outgoing
mail queue, without blocking the client (in our case, web nodes which
can't block on outgoing email).

Works with any MTA that has 'sendmail -i -f ....'

This might all be temporary until we figure out mail better.  (like
how to get postfix to trust our outgoing email and queue it
immediately, rather than blocking the web clients while it sends)


