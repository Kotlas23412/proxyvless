#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Убирает комментарии (фрагмент после #) в VPN-конфигах построчно и добавляет новый:
  # <флаг_страны><AUTO_COMMENT>
Страна определяется по IP хоста прокси (ip-api.com).
AUTO_COMMENT задаётся переменной окружения (см. .env и workflow).
"""

import argparse
import os
import socket
import sys
import time
import urllib.request
import ipaddress
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Загружаем .env при локальном запуске
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# Парсинг ссылки для извлечения хоста (address)
try:
    from lib.parsing import parse_proxy_url
except ImportError:
    parse_proxy_url = None

GEO_API = "http://ip-api.com/json/{ip}?fields=status,country,countryCode&lang=ru"
GEO_TIMEOUT = 3
GEO_DELAY = 0.2  # пауза перед запросом в каждом потоке (лимит ip-api.com ~45/мин без ключа)
# Потоки: DNS можно поднять до 24-32; geo - не выше 10-12, иначе легко 429 от ip-api
DNS_MAX_WORKERS = 32
GEO_MAX_WORKERS = 10

DEFAULT_AUTO_COMMENT = " verified · XRayCheck"
DEFAULT_COUNTRY_RU = "Неизвестная страна"

COUNTRY_RU_BY_CODE = {
    "AM": "Армения",
    "AZ": "Азербайджан",
    "BY": "Беларусь",
    "CN": "Китай",
    "DE": "Германия",
    "EE": "Эстония",
    "FI": "Финляндия",
    "FR": "Франция",
    "GB": "Великобритания",
    "GE": "Грузия",
    "HK": "Гонконг",
    "IL": "Израиль",
    "IN": "Индия",
    "IR": "Иран",
    "IT": "Италия",
    "JP": "Япония",
    "KZ": "Казахстан",
    "LT": "Литва",
    "LV": "Латвия",
    "MD": "Молдова",
    "NL": "Нидерланды",
    "PL": "Польша",
    "RO": "Румыния",
    "RS": "Сербия",
    "RU": "Россия",
    "SE": "Швеция",
    "SG": "Сингапур",
    "TR": "Турция",
    "UA": "Украина",
    "US": "США",
    "UZ": "Узбекистан",
}

# Быстрый режим: не делать DNS/HTTP-запросы, использовать фиксированный или глобальный флаг.
STRIP_FAST = (os.environ.get("STRIP_VPN_COMMENTS_FAST") or "").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
# Код страны по умолчанию для быстрого режима (например, RU), пусто = глобус.
STRIP_CC_DEFAULT = (os.environ.get("STRIP_VPN_COMMENTS_CC") or "").strip().upper()


def get_auto_comment() -> str:
    """Текст комментария из переменной окружения AUTO_COMMENT."""
    return os.environ.get("AUTO_COMMENT", DEFAULT_AUTO_COMMENT).strip() or DEFAULT_AUTO_COMMENT


def strip_comment_from_line(line: str) -> str:
    """Убирает из строки фрагмент (комментарий) после первого '#'."""
    line = line.strip()
    if not line or line.startswith("#"):
        return line
    return line.split("#", 1)[0].strip()


@@ -71,134 +107,195 @@ def country_code_to_flag(cc: str) -> str:


def get_host_from_link(link: str) -> str | None:
    """Извлекает хост (address) из прокси-ссылки."""
    if parse_proxy_url:
        parsed = parse_proxy_url(link)
        if parsed and isinstance(parsed.get("address"), str):
            return parsed["address"].strip()
    # Fallback: ищем @host:port в типичных схемах
    for prefix in ("vless://", "vmess://", "trojan://", "ss://", "hy2://", "hysteria2://", "hysteria://"):
        if link.startswith(prefix):
            rest = link[len(prefix) :].strip()
            if "?" in rest:
                rest = rest.split("?")[0]
            if "@" in rest:
                _, host_port = rest.rsplit("@", 1)
                if ":" in host_port:
                    return host_port.rpartition(":")[0].strip()
                return host_port.strip()
            if "://" in rest:
                return rest.split("/")[0].strip()
            break
    return None


def resolve_to_ips(host: str) -> list[str]:
    """Возвращает все IPv4 для хоста (в т.ч. если на входе уже IPv4)."""
    if not host:
        return []
    try:
        ip_obj = ipaddress.ip_address(host)
        return [str(ip_obj)] if ip_obj.version == 4 else []
    except ValueError:
        pass
    try:
        infos = socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_STREAM)
    except OSError:
        return []
    ips: set[str] = set()
    for info in infos:
        sockaddr = info[4]
        if sockaddr and sockaddr[0]:
            ips.add(sockaddr[0])
    return sorted(ips)


def country_code_to_ru_name(cc: str) -> str:
    cc = (cc or "").upper()
    return COUNTRY_RU_BY_CODE.get(cc, DEFAULT_COUNTRY_RU)


def fetch_country_for_ip(ip: str, cache: dict) -> tuple[str, str]:
    """Получает (countryCode, countryNameRu) для IP через ip-api.com; использует cache."""
    if ip in cache:
        return cache[ip]
    time.sleep(GEO_DELAY)
    try:
        req = urllib.request.Request(GEO_API.format(ip=ip), headers={"User-Agent": "XRayCheck/1.0"})
        with urllib.request.urlopen(req, timeout=GEO_TIMEOUT) as r:
            import json

            data = json.loads(r.read().decode())
            if (data.get("status") or "").lower() != "success":
                cache[ip] = ("", DEFAULT_COUNTRY_RU)
                return cache[ip]
            cc = (data.get("countryCode") or "").upper()
            country_ru = (data.get("country") or "").strip() or country_code_to_ru_name(cc)
            cache[ip] = (cc, country_ru)
            return cache[ip]
    except Exception:
        cache[ip] = ("", DEFAULT_COUNTRY_RU)
        return cache[ip]


def _load_cidr_networks(cidr_path: str) -> list[ipaddress.IPv4Network]:
    path = Path(cidr_path)
    if not path.is_file():
        return []
    networks: list[ipaddress.IPv4Network] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        try:
            n = ipaddress.ip_network(s, strict=False)
        except ValueError:
            continue
        if n.version == 4:
            networks.append(n)
    return networks


def _any_ip_in_cidr(ips: list[str], networks: list[ipaddress.IPv4Network]) -> bool:
    if not ips or not networks:
        return False
    for ip_text in ips:
        try:
            ip_obj = ipaddress.ip_address(ip_text)
        except ValueError:
            continue
        if ip_obj.version != 4:
            continue
        if any(ip_obj in net for net in networks):
            return True
    return False


def process_file(
    input_path: str,
    output_path: str | None,
    add_comment: bool = True,
) -> int:
    """Читает файл, убирает комментарии, опционально добавляет новый с флагом страны, пишет результат."""
    path = Path(input_path)
    if not path.is_file():
        print(f"Error: file not found: {path}", file=sys.stderr)
        return 0
    # По умолчанию пишем в исходный файл, чтобы изменения были видны сразу.
    out = Path(output_path) if output_path else path
    lines_in = path.read_text(encoding="utf-8").splitlines()

    # Предварительно разбираем строки в чистые ссылки и хосты
    links: list[str] = []
    hosts: list[str | None] = []
    for line in lines_in:
        link = strip_comment_from_line(line)
        if not link:
            continue
        links.append(link)
        hosts.append(get_host_from_link(link) if add_comment and not STRIP_FAST else None)

    geo_cache: dict[str, tuple[str, str]] = {}
    host_to_ips: dict[str, list[str]] = {}
    cidr_networks = _load_cidr_networks(os.environ.get("STRIP_VPN_COMMENTS_CIDR_PATH", "cidrlist"))

    if add_comment and not STRIP_FAST:
        # 1) Разрешаем все уникальные хосты в IP параллельно
        unique_hosts = sorted({h for h in hosts if h})

        def _resolve_host(h: str) -> None:
            host_to_ips[h] = resolve_to_ips(h)

        if unique_hosts:
            with ThreadPoolExecutor(max_workers=min(DNS_MAX_WORKERS, len(unique_hosts))) as executor:
                list(executor.map(_resolve_host, unique_hosts))

        # 2) Для всех уникальных IP получаем countryCode (с кэшем) тоже параллельно
        unique_ips = sorted({ip for ips in host_to_ips.values() for ip in ips if ip})

        def _fetch_cc(ip: str) -> None:
            fetch_country_for_ip(ip, geo_cache)

        if unique_ips:
            with ThreadPoolExecutor(max_workers=min(GEO_MAX_WORKERS, len(unique_ips))) as executor:
                list(executor.map(_fetch_cc, unique_ips))

    # 3) Собираем итоговые строки
    result: list[str] = []
    for link, host in zip(links, hosts):
        if add_comment:
            if STRIP_FAST:
                cc = STRIP_CC_DEFAULT or ""
                country_ru = country_code_to_ru_name(cc)
                is_lte = False
            else:
                ips = host_to_ips.get(host, []) if host else []
                variants = [geo_cache.get(ip, ("", DEFAULT_COUNTRY_RU)) for ip in ips]
                cc = next((v[0] for v in variants if v[0]), "")
                country_ru = next((v[1] for v in variants if v[0]), DEFAULT_COUNTRY_RU)
                is_lte = _any_ip_in_cidr(ips, cidr_networks)
                if is_lte and not cc:
                    cc = "RU"
                    country_ru = country_code_to_ru_name(cc)
            flag = country_code_to_flag(cc)
            lte_suffix = " | LTE" if is_lte else ""
            link = f"{link}#{flag} {country_ru}{lte_suffix} {get_auto_comment().strip()}"
        result.append(link)
    out.write_text("\n".join(result) + ("\n" if result else ""), encoding="utf-8")
    print(f"Processed: {len(lines_in)} lines -> {len(result)} with new comment. Output: {out}")
    return len(result)


def main():
    parser = argparse.ArgumentParser(
        description="Strip comments from VPN configs and add: # <flag> verified · XRayCheck"
    )
    parser.add_argument("input", help="Input file (one link per line)")
    parser.add_argument("-o", "--output", default=None, help="Output file (default: overwrite input file)")
    parser.add_argument("--no-comment", action="store_true", help="Only strip comments, do not add new one")
    args = parser.parse_args()
    n = process_file(args.input, args.output, add_comment=not args.no_comment)
    sys.exit(0 if n > 0 else 1)


if __name__ == "__main__":
    main()