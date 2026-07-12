$ test_custom_types

@type uuid = s36
@type email = s128
@type ip_addr mysql=s45 postgres=inet sqlite=s45

# user
id n++
uuid uuid *
email email *
name s64 *
ip ip_addr
