package JawnOS::Routes::manager_misc3;

use strict;
use warnings;

sub routes {
	return (
	[9883, 'get', '/manager/vault_share', 'action_9883'],
	[9907, 'get', '/manager/legacy_reseal', 'action_9907'],
	[9920, 'post', '/manager/key_push', 'action_9920'],
	[9944, 'post', '/manager/operator_door', 'action_9944'],
	[10187, 'post', '/manager/self_deploy', 'action_10187'],
	[10288, 'get', '/manager/code_bundle', 'action_10288'],
	[10311, 'get', '/manager/app_release', 'action_10311'],
	[10322, 'get', '/manager/app_download', 'action_10322'],
	[10345, 'post', '/manager/app_release_sync', 'action_10345'],
	[10358, 'get', '/manager/ollama_models', 'action_10358'],
	[10378, 'post', '/manager/ollama_chat', 'action_10378'],
	[10408, 'get', '/manager/crew/state', 'action_10408'],
	[10415, 'post', '/manager/crew/job', 'action_10415'],
	[10477, 'post', '/manager/crew/advertise', 'action_10477'],
	[10513, 'get', '/manager/voice_release', 'action_10513'],
	[10521, 'get', '/manager/voice_download', 'action_10521'],
	[11014, 'get', '/manager/sync_rows', 'action_11014'],
	[11091, 'get', '/manager/sync_tombstones', 'action_11091'],
	[11111, 'get', '/manager/sync_buckets', 'action_11111'],
	[11638, 'post', '/manager/backup/confirm', 'action_11638'],
	[11740, 'get', '/manager/remote_manager', 'action_11740'],
	);
}

1;
