import tasks

s = tasks.stats(tasks.make_client(socket_timeout=2))
print("queue: waiting=%(waiting)d in_flight=%(pending)d oldest_age_s=%(oldest_age_s).1f dead=%(dead)d naive_list=%(naive_list)d" % s)
