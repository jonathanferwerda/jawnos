package JawnOS::Routes::manager_store;

use strict;
use warnings;

sub routes {
	return (
	[5518, 'get', '/manager/store', 'action_5518'],
	[5955, 'get', '/manager/store/custom_item/toggle', 'action_5955'],
	[5969, 'post', '/manager/store/custom_item/add', 'action_5969'],
	[6013, 'get', '/manager/store/customer_search', 'action_6013'],
	[6041, 'get', '/manager/store/customer_load', 'action_6041'],
	[6378, 'get', '/manager/store/customer_list', 'action_6378'],
	[6410, 'get', '/manager/store/customer_register', 'action_6410'],
	[6411, 'get', '/manager/store/register', 'action_6411'],
	[6412, 'get', '/manager/store/register/state', 'action_6412'],
	[6413, 'post', '/manager/store/register/order', 'action_6413'],
	[6414, 'get', '/manager/store/register/items', 'action_6414'],
	[6415, 'post', '/manager/store/register/item', 'action_6415'],
	[6416, 'post', '/manager/store/register/quantity', 'action_6416'],
	[6417, 'post', '/manager/store/register/remove', 'action_6417'],
	[6418, 'post', '/manager/store/register/cancel', 'action_6418'],
	[6419, 'post', '/manager/store/register/sale', 'action_6419'],
	[6420, 'get', '/manager/store/register/receipt', 'action_6420'],
	[6466, 'get', '/manager/store/customer_correspondence', 'action_6466'],
	[6625, 'post', '/manager/store/:att/save', 'action_6625'],
	[6809, 'post', '/manager/store/attribute_characteristic_setter', 'action_6809'],
	[6878, 'post', '/manager/store/characteristic_delete', 'action_6878'],
	[6893, 'post', '/manager/store/attribute_delete', 'action_6893'],
	[6901, 'post', '/manager/store/appointment_model_migration', 'action_6901'],
	[6919, 'post', '/manager/store/appointment_model_selector', 'action_6919'],
	);
}

1;
