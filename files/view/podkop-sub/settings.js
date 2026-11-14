'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return fs.read('/tmp/podkop-sub.status').catch(function() { return ''; });
	},

	render: function(status) {
		var m, s, o;
		var statusText = (status || '').trim() || _('ещё не запускалось');

		m = new form.Map('podkop_sub',
			_('VPN-подписка'),
			_('Источник ссылок для Podkop. Скрипт сам обновляет список узлов по расписанию (каждые 6 часов) и при нажатии кнопки ниже.'));

		s = m.section(form.NamedSection, 'settings', 'settings', _('Параметры'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'url', _('URL подписки'),
			_('Ссылка вида https://…/keys/… — та, что выдал провайдер.'));
		o.rmempty = false;
		o.placeholder = 'https://example.com/keys/000000/XXXX';

		o = s.option(form.Value, 'top_n', _('Сколько узлов держать'),
			_('Из подписки выбираются серверы с наименьшей задержкой.'));
		o.datatype = 'range(1,20)';
		o.placeholder = '6';
		o.default = '6';

		o = s.option(form.Value, 'min_count', _('Минимум ссылок в подписке'),
			_('Защита от пустой подписки: если ссылок меньше, рабочий список не меняется.'));
		o.datatype = 'range(1,50)';
		o.placeholder = '5';
		o.default = '5';

		o = s.option(form.Flag, 'enabled', _('Автообновление включено'),
			_('Выключите, чтобы скрипт перестал трогать Podkop.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Button, '_run', _('Обновить сейчас'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return fs.exec('/usr/bin/podkop-sub-update.sh').then(function() {
				return fs.read('/tmp/podkop-sub.status').catch(function() { return ''; });
			}).then(function(txt) {
				ui.addNotification(null, E('p', {}, (txt || '').trim() || _('Скрипт выполнен')), 'info');
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Ошибка запуска: %s').format(err)), 'danger');
			});
		};

		o = s.option(form.DummyValue, '_status', _('Последний запуск'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<em>' + statusText.replace(/</g, '&lt;') + '</em>';
		};

		return m.render();
	}
});
