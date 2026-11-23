import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shun/presentation/localization/localized_widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'management_style.dart';

class DockerImageBadge extends StatelessWidget {
  const DockerImageBadge({super.key, required this.imageName});

  final String imageName;

  @override
  Widget build(BuildContext context) {
    final brand = _dockerBrand(imageName);
    return Tooltip(
      message: brand.name,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: managementFill(context),
          shape: prism.AppShape.md,
        ),
        child: brand.asset == null
            ? LText(
                brand.mark,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                  fontSize: brand.mark.length > 2 ? 10 : 14,
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(9),
                child: SvgPicture.asset(brand.asset!,
                    colorFilter: ColorFilter.mode(
                        Theme.of(context).colorScheme.onSurface,
                        BlendMode.srcIn)),
              ),
      ),
    );
  }
}

class _DockerBrand {
  const _DockerBrand(this.name, this.mark, {this.asset});

  final String name;
  final String mark;
  final String? asset;
}

_DockerBrand _dockerBrand(String value) {
  final name = value.toLowerCase();
  const rules = <(String, _DockerBrand)>[
    (
      'nginx',
      _DockerBrand(
        'nginx',
        'N',
        asset: 'assets/docker/nginx.svg',
      ),
    ),
    (
      'redis',
      _DockerBrand(
        'Redis',
        'R',
        asset: 'assets/docker/redis.svg',
      ),
    ),
    ('valkey', _DockerBrand('Valkey', 'V')),
    (
      'postgres',
      _DockerBrand(
        'PostgreSQL',
        'PG',
        asset: 'assets/docker/postgresql.svg',
      ),
    ),
    ('mariadb', _DockerBrand('MariaDB', 'M')),
    ('mysql', _DockerBrand('MySQL', 'My')),
    ('mongo', _DockerBrand('MongoDB', 'M')),
    ('rabbitmq', _DockerBrand('RabbitMQ', 'RMQ')),
    ('kafka', _DockerBrand('Kafka', 'K')),
    ('elasticsearch', _DockerBrand('Elasticsearch', 'ES')),
    ('opensearch', _DockerBrand('OpenSearch', 'OS')),
    ('grafana', _DockerBrand('Grafana', 'G')),
    ('prometheus', _DockerBrand('Prometheus', 'P')),
    ('node', _DockerBrand('Node.js', 'JS')),
    ('python', _DockerBrand('Python', 'Py')),
    ('golang', _DockerBrand('Go', 'Go')),
    ('openjdk', _DockerBrand('OpenJDK', 'J')),
    ('wordpress', _DockerBrand('WordPress', 'W')),
    ('alpine', _DockerBrand('Alpine', 'A')),
    ('ubuntu', _DockerBrand('Ubuntu', 'U')),
    ('debian', _DockerBrand('Debian', 'D')),
  ];
  for (final rule in rules) {
    if (name.contains(rule.$1)) return rule.$2;
  }
  return const _DockerBrand(
    'Docker image',
    '◆',
    asset: 'assets/docker/container.svg',
  );
}
