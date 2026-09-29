// Сгенерировано gen_fixtures.py (кодеки Python: cp1251/koi8-r/quopri/base64) — эталонные данные.
// Не редактировать вручную: кодировки проверяются независимо от таблиц UniMail.

enum Fixtures {
    static let outlook = #"""
Received: from mx.corp.ru (mx.corp.ru [10.0.0.1])
	by mail.example.ru with ESMTPS id 12345
	for <petrov@example.ru>; Tue, 29 Sep 2026 10:15:02 +0300
From: =?windows-1251?B?yOLg7e7iIMji4O0gyOLg7e7i6Pc=?= <ivanov@corp.ru>
To: =?koi8-r?Q?=F0=C5=D4=D2=CF=D7_=F0=A3=D4=D2?= <petrov@example.ru>,
	"Сидорова, Анна" <sidorova@example.ru>
CC: 'Бухгалтерия' <buh@corp.ru>
Subject: =?windows-1251?B?zvL3uPIg5+Ag8eXt8v/h8Pw=?=
Thread-Topic: =?windows-1251?B?zvL3uPIg5+Ag8eXt8v/h8Pw=?=
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

=CA=EE=EB=EB=E5=E3=E8, =E4=EE=E1=F0=FB=E9 =E4=E5=ED=FC!

=CE=F2=F7=B8=F2 =E2=EE =E2=EB=EE=E6=E5=ED=E8=E8 =97 =F1=EC=EE=F2=F0=E8=F2=
=E5 =EA=E0=F0=F2=E8=ED=EA=F3 =ED=E8=E6=E5.

=D1 =F3=E2=E0=E6=E5=ED=E8=E5=EC,
=C8=E2=E0=ED
--_000_AM0PR01MB1234ABCD_
Content-Type: text/html; charset="windows-1251"
Content-Transfer-Encoding: quoted-printable

<html><body><p>=CA=EE=EB=EB=E5=E3=E8, =E4=EE=E1=F0=FB=E9 =E4=E5=ED=FC!</p><=
p><img src=3D"cid:image001.png@01DB1234.56789AB0" width=3D10></p><p>=D1 =F3=
=E2=E0=E6=E5=ED=E8=E5=EC, =C8=E2=E0=ED</p></body></html>
--_000_AM0PR01MB1234ABCD_--

--_004_AM0PR01MB1234ABCD_
Content-Type: image/png; name="image001.png"
Content-Description: image001.png
Content-Disposition: inline; filename="image001.png"; size=72;
	creation-date="Tue, 29 Sep 2026 07:14:59 GMT";
	modification-date="Tue, 29 Sep 2026 07:14:59 GMT"
Content-ID: <image001.png@01DB1234.56789AB0>
Content-Transfer-Encoding: base64

iVBORw0KGgoAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w
MTIzNDU2Nzg5Ojs8PT4/

--_004_AM0PR01MB1234ABCD_--

"""#
    static let outlookPNGBase64 = #"""
iVBORw0KGgoAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/
"""#
    static let mixed = #"""
From: "Бухгалтерия ООО \"Ромашка\"" <buh@romashka.ru>
To: client@example.com
Subject: =?koi8-r?Q?=F3=CF=D7=C5=DD=C1=CE=C9=C5_=D7_=D0=D1=D4=CE=C9=C3=D5?=
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

=D0=94=D0=BE=D0=B1=D1=80=D1=8B=D0=B9 =D0=B4=D0=B5=D0=BD=D1=8C!
=D0=92=D0=BE =D0=B2=D0=BB=D0=BE=D0=B6=D0=B5=D0=BD=D0=B8=D0=B8 =D1=81=D1=87=
=D1=91=D1=82. =D0=A1=D1=82=D1=80=D0=BE=D0=BA=D0=B0, =D0=BA=D0=BE=D1=82=D0=
=BE=D1=80=D0=B0=D1=8F =D0=B4=D0=BE=D1=81=D1=82=D0=B0=D1=82=D0=BE=D1=87=D0=
=BD=D0=BE =D0=B4=D0=BB=D0=B8=D0=BD=D0=BD=D0=B0=D1=8F, =D1=87=D1=82=D0=BE=D0=
=B1=D1=8B quoted-printable =D0=BF=D0=B5=D1=80=D0=B5=D0=BD=D1=91=D1=81 =D0=
=B5=D1=91 =D0=BC=D1=8F=D0=B3=D0=BA=D0=B8=D0=BC =D0=BF=D0=B5=D1=80=D0=B5=D0=
=BD=D0=BE=D1=81=D0=BE=D0=BC =D0=BF=D0=BE=D1=81=D0=B5=D1=80=D0=B5=D0=B4=D0=
=B8=D0=BD=D0=B5.
.=D1=82=D0=BE=D1=87=D0=BA=D0=B0 =D0=B2 =D0=BD=D0=B0=D1=87=D0=B0=D0=BB=D0=B5=
 =D1=81=D1=82=D1=80=D0=BE=D0=BA=D0=B8
--inner
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: base64

PGRpdiBkaXI9Imx0ciI+0JTQvtCx0YDRi9C5INC00LXQvdGMITxicj7QktC+INCy0LvQvtC20LXQ
vdC40LggPGI+0YHRh9GR0YI8L2I+LjwvZGl2Pg==
--inner--

--outer
Content-Type: application/pdf; name="=?utf-8?B?0KHRh9GR0YIg0L3QsCDQvtC/0LvQsNGC0YMg4oSWMTUg0L7RgiAyOS4wOS4yMDI2LnBkZg==?="
Content-Disposition: attachment;
 filename*0*=utf-8''%D0%A1%D1%87%D1%91%D1%82%20%D0%BD%D0%B0%20%D0%BE%D0%BF%D0%BB%D0;
 filename*1*=%B0%D1%82%D1%83%20%E2%84%9615%20%D0%BE%D1%82%2029.09.2026.pdf
Content-Transfer-Encoding: base64

JVBERi0xLjQKJeLjz9MKMSAwIG9iajw8Pj5lbmRvYmoKdHJhaWxlcjw8Pj4KJSVFT0YK
--outer--
epilogue text

"""#
    static let mixedText = #"""
Добрый день!
Во вложении счёт. Строка, которая достаточно длинная, чтобы quoted-printable перенёс её мягким переносом посередине.
.точка в начале строки
"""#
    static let mixedHTML = #"""
<div dir="ltr">Добрый день!<br>Во вложении <b>счёт</b>.</div>
"""#
    static let mixedPDFBase64 = #"""
JVBERi0xLjQKJeLjz9MKMSAwIG9iajw8Pj5lbmRvYmoKdHJhaWxlcjw8Pj4KJSVFT0YK
"""#
    static let pdfName = #"""
Счёт на оплату №15 от 29.09.2026.pdf
"""#
    static let gmail = #"""
Delivered-To: me@gmail.com
Received: by 2002:a05:6a10:1234 with SMTP id abc;
        Tue, 29 Sep 2026 04:01:02 -0700 (PDT)
MIME-Version: 1.0
References: <CAB1234abc@mail.gmail.com>
 <CAC5678def@mail.gmail.com>	<CAD9999xyz@mail.gmail.com>
In-Reply-To: <CAD9999xyz@mail.gmail.com>
From: Alexey Smirnov <alexey.smirnov@gmail.com>
Date: Tue, 29 Sep 2026 14:00:51 +0300
Message-ID: <CAE+0kX=Y1a2b3c4d5e6f7g8h9-Q@mail.gmail.com>
Subject: =?UTF-8?B?0JLRgdGC0Q==?=
 =?UTF-8?B?gNC10YfQsCDQv9C+INC/0YDQvtC10LrRgtGDIMKr0K7QvdC40LzQtdC50LvCuw==?=
To: =?UTF-8?B?0JzQvtC5INCv0YnQuNC6?= <me@gmail.com>
List-Unsubscribe: <mailto:unsub@list.example.com?subject=unsubscribe>,
 <https://list.example.com/unsub?id=42&t=abc>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
Content-Type: multipart/alternative; boundary="0000000000004ce5a0060e1a2b3c"

--0000000000004ce5a0060e1a2b3c
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82!

=D0=94=D0=B0=D0=B2=D0=B0=D0=B9 =D0=B2=D1=81=D1=82=D1=80=D0=B5=D1=82=D0=B8=
=D0=BC=D1=81=D1=8F =D0=B2 =D1=87=D0=B5=D1=82=D0=B2=D0=B5=D1=80=D0=B3 =D0=B2=
 15:00. =D0=A1=D1=81=D1=8B=D0=BB=D0=BA=D0=B0: https://meet.google.com/abc-d=
efg-hij

--=20
=D0=90=D0=BB=D0=B5=D0=BA=D1=81=D0=B5=D0=B9
--0000000000004ce5a0060e1a2b3c
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

<div dir=3D"ltr">=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82!<div><br></div><div>=
=D0=94=D0=B0=D0=B2=D0=B0=D0=B9 =D0=B2=D1=81=D1=82=D1=80=D0=B5=D1=82=D0=B8=
=D0=BC=D1=81=D1=8F =D0=B2 =D1=87=D0=B5=D1=82=D0=B2=D0=B5=D1=80=D0=B3 =D0=B2=
 15:00.</div></div>
--0000000000004ce5a0060e1a2b3c--

"""#
    static let gmailSubject = #"""
Встреча по проекту «Юнимейл»
"""#
    static let gmailText = #"""
Привет!

Давай встретимся в четверг в 15:00. Ссылка: https://meet.google.com/abc-defg-hij

-- 
Алексей
"""#
    static let gmailHTML = #"""
<div dir="ltr">Привет!<div><br></div><div>Давай встретимся в четверг в 15:00.</div></div>
"""#
    static let outlookICS = #"""
BEGIN:VCALENDAR
METHOD:REQUEST
PRODID:Microsoft Exchange Server 2010
VERSION:2.0
BEGIN:VTIMEZONE
TZID:Russian Standard Time
BEGIN:STANDARD
DTSTART:16010101T000000
TZOFFSETFROM:+0300
TZOFFSETTO:+0300
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:16010101T000000
TZOFFSETFROM:+0300
TZOFFSETTO:+0300
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
ORGANIZER;CN="Петров, Пётр":mailto:petrov@corp.ru
ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Иванов Иван:mailto:iv
 anov@corp.ru
ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Сидорова Анна:mailto:sidorova@corp.ru
DESCRIPTION;LANGUAGE=ru-RU:Повестка:\n1. Итоги квартала\n2. Планы\, бюджет\; сроки\n
UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F6D901000000000000000010000000
 1234567890ABCDEF
SUMMARY;LANGUAGE=ru-RU:Планёрка отдела
DTSTART;TZID=Russian Standard Time:20261005T100000
DTEND;TZID=Russian Standard Time:20261005T113000
CLASS:PUBLIC
PRIORITY:5
DTSTAMP:20260929T071500Z
TRANSP:OPAQUE
STATUS:CONFIRMED
SEQUENCE:2
LOCATION;LANGUAGE=ru-RU:Переговорная 5\, 3 этаж
BEGIN:VALARM
DESCRIPTION:REMINDER
TRIGGER;RELATED=START:-PT15M
ACTION:DISPLAY
END:VALARM
END:VEVENT
END:VCALENDAR

"""#
    static let invite = #"""
From: =?utf-8?B?0J/QtdGC0YDQvtCyLCDQn9GR0YLRgA==?= <petrov@corp.ru>
To: ivanov@corp.ru
Subject: =?utf-8?B?0J/Qu9Cw0L3RkdGA0LrQsCDQvtGC0LTQtdC70LA=?=
Date: Tue, 29 Sep 2026 10:20:00 +0300
Message-ID: <invite-1@corp.ru>
Content-Type: multipart/alternative; boundary="_000_invite_"
MIME-Version: 1.0

--_000_invite_
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: base64

0J/QvtCy0LXRgdGC0LrQsDog0LjRgtC+0LPQuCDQutCy0LDRgNGC0LDQu9Cw

--_000_invite_
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: base64

PHA+0J/QvtCy0LXRgdGC0LrQsDog0LjRgtC+0LPQuCDQutCy0LDRgNGC0LDQu9CwPC9wPg==

--_000_invite_
Content-Type: text/calendar; charset="utf-8"; method=REQUEST
Content-Transfer-Encoding: base64

QkVHSU46VkNBTEVOREFSDQpNRVRIT0Q6UkVRVUVTVA0KUFJPRElEOk1pY3Jvc29mdCBFeGNoYW5n
ZSBTZXJ2ZXIgMjAxMA0KVkVSU0lPTjoyLjANCkJFR0lOOlZUSU1FWk9ORQ0KVFpJRDpSdXNzaWFu
IFN0YW5kYXJkIFRpbWUNCkJFR0lOOlNUQU5EQVJEDQpEVFNUQVJUOjE2MDEwMTAxVDAwMDAwMA0K
VFpPRkZTRVRGUk9NOiswMzAwDQpUWk9GRlNFVFRPOiswMzAwDQpFTkQ6U1RBTkRBUkQNCkJFR0lO
OkRBWUxJR0hUDQpEVFNUQVJUOjE2MDEwMTAxVDAwMDAwMA0KVFpPRkZTRVRGUk9NOiswMzAwDQpU
Wk9GRlNFVFRPOiswMzAwDQpFTkQ6REFZTElHSFQNCkVORDpWVElNRVpPTkUNCkJFR0lOOlZFVkVO
VA0KT1JHQU5JWkVSO0NOPSLQn9C10YLRgNC+0LIsINCf0ZHRgtGAIjptYWlsdG86cGV0cm92QGNv
cnAucnUNCkFUVEVOREVFO1JPTEU9UkVRLVBBUlRJQ0lQQU5UO1BBUlRTVEFUPU5FRURTLUFDVElP
TjtSU1ZQPVRSVUU7Q0490JjQstCw0L3QvtCyINCY0LLQsNC9Om1haWx0bzppdg0KIGFub3ZAY29y
cC5ydQ0KQVRURU5ERUU7Uk9MRT1PUFQtUEFSVElDSVBBTlQ7UEFSVFNUQVQ9TkVFRFMtQUNUSU9O
O1JTVlA9VFJVRTtDTj3QodC40LTQvtGA0L7QstCwINCQ0L3QvdCwOm1haWx0bzpzaWRvcm92YUBj
b3JwLnJ1DQpERVNDUklQVElPTjtMQU5HVUFHRT1ydS1SVTrQn9C+0LLQtdGB0YLQutCwOlxuMS4g
0JjRgtC+0LPQuCDQutCy0LDRgNGC0LDQu9CwXG4yLiDQn9C70LDQvdGLXCwg0LHRjtC00LbQtdGC
XDsg0YHRgNC+0LrQuFxuDQpVSUQ6MDQwMDAwMDA4MjAwRTAwMDc0QzVCNzEwMUE4MkUwMDgwMDAw
MDAwMEExQjJDM0Q0RTVGNkQ5MDEwMDAwMDAwMDAwMDAwMDAwMTAwMDAwMDANCiAxMjM0NTY3ODkw
QUJDREVGDQpTVU1NQVJZO0xBTkdVQUdFPXJ1LVJVOtCf0LvQsNC90ZHRgNC60LAg0L7RgtC00LXQ
u9CwDQpEVFNUQVJUO1RaSUQ9UnVzc2lhbiBTdGFuZGFyZCBUaW1lOjIwMjYxMDA1VDEwMDAwMA0K
RFRFTkQ7VFpJRD1SdXNzaWFuIFN0YW5kYXJkIFRpbWU6MjAyNjEwMDVUMTEzMDAwDQpDTEFTUzpQ
VUJMSUMNClBSSU9SSVRZOjUNCkRUU1RBTVA6MjAyNjA5MjlUMDcxNTAwWg0KVFJBTlNQOk9QQVFV
RQ0KU1RBVFVTOkNPTkZJUk1FRA0KU0VRVUVOQ0U6Mg0KTE9DQVRJT047TEFOR1VBR0U9cnUtUlU6
0J/QtdGA0LXQs9C+0LLQvtGA0L3QsNGPIDVcLCAzINGN0YLQsNC2DQpCRUdJTjpWQUxBUk0NCkRF
U0NSSVBUSU9OOlJFTUlOREVSDQpUUklHR0VSO1JFTEFURUQ9U1RBUlQ6LVBUMTVNDQpBQ1RJT046
RElTUExBWQ0KRU5EOlZBTEFSTQ0KRU5EOlZFVkVOVA0KRU5EOlZDQUxFTkRBUg0K

--_000_invite_--

"""#
}
