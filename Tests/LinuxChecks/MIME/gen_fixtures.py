#!/usr/bin/env python3
# Генератор эталонных писем для Tests/LinuxChecks/MIME (кодировки — стандартными кодеками Python).
# Запуск: python3 gen_fixtures.py → перезаписывает Fixtures.swift рядом.
import base64, quopri, urllib.parse, os
def b64(s, cs): return base64.b64encode(s.encode(cs)).decode()
def qword(s, cs):
    out=''
    for b in s.encode(cs):
        c=chr(b)
        if c==' ': out+='_'
        elif c.isalnum() and b<128: out+=c
        else: out+='=%02X'%b
    return out
def qp(s, cs='utf-8'):
    return quopri.encodestring(s.replace('\n','\r\n').encode(cs)).decode().replace('\r\n','\n')
def b64lines(data):
    e=base64.b64encode(data).decode()
    return '\n'.join(e[i:i+76] for i in range(0,len(e),76))

fx={}
# 1. Outlook-style cp1251 with inline image
subj1='Отчёт за сентябрь'
from1='Иванов Иван Иванович'
text1='Коллеги, добрый день!\n\nОтчёт во вложении — смотрите картинку ниже.\n\nС уважением,\nИван'
html1='<html><body><p>Коллеги, добрый день!</p><p><img src="cid:image001.png@01DB1234.56789AB0" width=10></p><p>С уважением, Иван</p></body></html>'
png=bytes([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]+list(range(0,64)))
fx['outlook']=f'''Received: from mx.corp.ru (mx.corp.ru [10.0.0.1])
	by mail.example.ru with ESMTPS id 12345
	for <petrov@example.ru>; Tue, 29 Sep 2026 10:15:02 +0300
From: =?windows-1251?B?{b64(from1,'cp1251')}?= <ivanov@corp.ru>
To: =?koi8-r?Q?{qword('Петров Пётр','koi8-r')}?= <petrov@example.ru>,
	"Сидорова, Анна" <sidorova@example.ru>
CC: 'Бухгалтерия' <buh@corp.ru>
Subject: =?windows-1251?B?{b64(subj1,'cp1251')}?=
Thread-Topic: =?windows-1251?B?{b64(subj1,'cp1251')}?=
Thread-Index: AdtCmxYzAbCdEfGh
Date: Tue, 29 Sep 2026 07:15:00 +0000
Message-ID: <AM0PR01MB1234ABCD@AM0PR01MB1234.eurprd01.prod.outlook.com>
Accept-Language: ru-RU, en-US
Content-Language: ru-RU
X-MS-Has-Attach: yes
Content-Type: multipart/related;
	boundary="_004_AM0PR01MB1234ABCD_";
	type="multipart/alternative"
MIME-Version: 1.0

--_004_AM0PR01MB1234ABCD_
Content-Type: multipart/alternative;
	boundary="_000_AM0PR01MB1234ABCD_"

--_000_AM0PR01MB1234ABCD_
Content-Type: text/plain; charset="windows-1251"
Content-Transfer-Encoding: quoted-printable

{qp(text1,'cp1251')}
--_000_AM0PR01MB1234ABCD_
Content-Type: text/html; charset="windows-1251"
Content-Transfer-Encoding: quoted-printable

{qp(html1,'cp1251')}
--_000_AM0PR01MB1234ABCD_--

--_004_AM0PR01MB1234ABCD_
Content-Type: image/png; name="image001.png"
Content-Description: image001.png
Content-Disposition: inline; filename="image001.png"; size={len(png)};
	creation-date="Tue, 29 Sep 2026 07:14:59 GMT";
	modification-date="Tue, 29 Sep 2026 07:14:59 GMT"
Content-ID: <image001.png@01DB1234.56789AB0>
Content-Transfer-Encoding: base64

{b64lines(png)}

--_004_AM0PR01MB1234ABCD_--
'''
fx['outlookPNGBase64']=base64.b64encode(png).decode()

# 2. mixed(alternative(qp text, b64 html), pdf with RFC2231 continuation)
fname='Счёт на оплату №15 от 29.09.2026.pdf'
enc=urllib.parse.quote(fname.encode('utf-8'), safe='')
half=len(enc)//2
while enc[half-1]=='%' or enc[half-2]=='%': half+=1
text2='Добрый день!\nВо вложении счёт. Строка, которая достаточно длинная, чтобы quoted-printable перенёс её мягким переносом посередине.\n.точка в начале строки'
html2='<div dir="ltr">Добрый день!<br>Во вложении <b>счёт</b>.</div>'
pdf=b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'
fx['mixed']=f'''From: "Бухгалтерия ООО \\"Ромашка\\"" <buh@romashka.ru>
To: client@example.com
Subject: =?koi8-r?Q?{qword('Совещание в пятницу','koi8-r')}?=
Date: Mon, 28 Sep 2026 18:00:00 +0300 (MSK)
Message-ID: <mixed-1@romashka.ru>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer"

This is a multi-part message in MIME format.

--outer
Content-Type: multipart/alternative; boundary="inner"

--inner
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

{qp(text2)}
--inner
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: base64

{b64lines(html2.encode())}
--inner--

--outer
Content-Type: application/pdf; name="=?utf-8?B?{b64(fname,'utf-8')}?="
Content-Disposition: attachment;
 filename*0*=utf-8''{enc[:half]};
 filename*1*={enc[half:]}
Content-Transfer-Encoding: base64

{b64lines(pdf)}
--outer--
epilogue text
'''
fx['mixedText']=text2
fx['mixedHTML']=html2
fx['mixedPDFBase64']=base64.b64encode(pdf).decode()
fx['pdfName']=fname

# 3. Gmail-style
subj3='Встреча по проекту «Юнимейл»'
sb=subj3.encode()
cut=7  # middle of a 2-byte char
w1=base64.b64encode(sb[:cut]).decode(); w2=base64.b64encode(sb[cut:]).decode()
text3='Привет!\n\nДавай встретимся в четверг в 15:00. Ссылка: https://meet.google.com/abc-defg-hij\n\n-- \nАлексей'
html3='<div dir="ltr">Привет!<div><br></div><div>Давай встретимся в четверг в 15:00.</div></div>'
fx['gmail']=f'''Delivered-To: me@gmail.com
Received: by 2002:a05:6a10:1234 with SMTP id abc;
        Tue, 29 Sep 2026 04:01:02 -0700 (PDT)
MIME-Version: 1.0
References: <CAB1234abc@mail.gmail.com>
 <CAC5678def@mail.gmail.com>	<CAD9999xyz@mail.gmail.com>
In-Reply-To: <CAD9999xyz@mail.gmail.com>
From: Alexey Smirnov <alexey.smirnov@gmail.com>
Date: Tue, 29 Sep 2026 14:00:51 +0300
Message-ID: <CAE+0kX=Y1a2b3c4d5e6f7g8h9-Q@mail.gmail.com>
Subject: =?UTF-8?B?{w1}?=
 =?UTF-8?B?{w2}?=
To: =?UTF-8?B?{b64('Мой Ящик','utf-8')}?= <me@gmail.com>
List-Unsubscribe: <mailto:unsub@list.example.com?subject=unsubscribe>,
 <https://list.example.com/unsub?id=42&t=abc>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
Content-Type: multipart/alternative; boundary="0000000000004ce5a0060e1a2b3c"

--0000000000004ce5a0060e1a2b3c
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

{qp(text3)}
--0000000000004ce5a0060e1a2b3c
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

{qp(html3)}
--0000000000004ce5a0060e1a2b3c--
'''
fx['gmailSubject']=subj3
fx['gmailText']=text3
fx['gmailHTML']=html3

# 4. Outlook invite
ics=('BEGIN:VCALENDAR\nMETHOD:REQUEST\nPRODID:Microsoft Exchange Server 2010\nVERSION:2.0\n'
'BEGIN:VTIMEZONE\nTZID:Russian Standard Time\nBEGIN:STANDARD\nDTSTART:16010101T000000\nTZOFFSETFROM:+0300\nTZOFFSETTO:+0300\nEND:STANDARD\n'
'BEGIN:DAYLIGHT\nDTSTART:16010101T000000\nTZOFFSETFROM:+0300\nTZOFFSETTO:+0300\nEND:DAYLIGHT\nEND:VTIMEZONE\n'
'BEGIN:VEVENT\nORGANIZER;CN="Петров, Пётр":mailto:petrov@corp.ru\n'
'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Иванов Иван:mailto:iv\n anov@corp.ru\n'
'ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Сидорова Анна:mailto:sidorova@corp.ru\n'
'DESCRIPTION;LANGUAGE=ru-RU:Повестка:\\n1. Итоги квартала\\n2. Планы\\, бюджет\; сроки\\n\n'
'UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F6D901000000000000000010000000\n 1234567890ABCDEF\n'
'SUMMARY;LANGUAGE=ru-RU:Планёрка отдела\n'
'DTSTART;TZID=Russian Standard Time:20261005T100000\n'
'DTEND;TZID=Russian Standard Time:20261005T113000\n'
'CLASS:PUBLIC\nPRIORITY:5\nDTSTAMP:20260929T071500Z\nTRANSP:OPAQUE\nSTATUS:CONFIRMED\nSEQUENCE:2\n'
'LOCATION;LANGUAGE=ru-RU:Переговорная 5\\, 3 этаж\n'
'BEGIN:VALARM\nDESCRIPTION:REMINDER\nTRIGGER;RELATED=START:-PT15M\nACTION:DISPLAY\nEND:VALARM\n'
'END:VEVENT\nEND:VCALENDAR\n')
fx['outlookICS']=ics
ics_crlf=ics.replace('\n','\r\n')
fx['invite']=f'''From: =?utf-8?B?{b64('Петров, Пётр','utf-8')}?= <petrov@corp.ru>
To: ivanov@corp.ru
Subject: =?utf-8?B?{b64('Планёрка отдела','utf-8')}?=
Date: Tue, 29 Sep 2026 10:20:00 +0300
Message-ID: <invite-1@corp.ru>
Content-Type: multipart/alternative; boundary="_000_invite_"
MIME-Version: 1.0

--_000_invite_
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: base64

{b64lines('Повестка: итоги квартала'.encode())}

--_000_invite_
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: base64

{b64lines('<p>Повестка: итоги квартала</p>'.encode())}

--_000_invite_
Content-Type: text/calendar; charset="utf-8"; method=REQUEST
Content-Transfer-Encoding: base64

{b64lines(ics_crlf.encode())}

--_000_invite_--
'''

def lit(s):
    # Swift raw multi-line string literal
    return '#"""\n' + s + '\n"""#'
out=['// Сгенерировано gen_fixtures.py (кодеки Python: cp1251/koi8-r/quopri/base64) — эталонные данные.','// Не редактировать вручную: кодировки проверяются независимо от таблиц UniMail.','']
out.append('enum Fixtures {')
for k,v in fx.items():
    out.append(f'    static let {k} = {lit(v)}')
out.append('}')
open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'Fixtures.swift'),'w').write('\n'.join(out)+'\n')
