{{/*
Expand the name of the chart.
*/}}
{{- define "rbt-data-generator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rbt-data-generator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "rbt-data-generator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "rbt-data-generator.labels" -}}
helm.sh/chart: {{ include "rbt-data-generator.chart" . }}
{{ include "rbt-data-generator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "rbt-data-generator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rbt-data-generator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "rbt-data-generator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rbt-data-generator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Fully qualified rbt image reference.
*/}}
{{- define "rbt-data-generator.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- end }}

{{/*
Name of the DB credentials Secret (chart-created or user-supplied).
*/}}
{{- define "rbt-data-generator.secretName" -}}
{{- if .Values.auth.existingSecret }}
{{- .Values.auth.existingSecret }}
{{- else }}
{{- printf "%s-db" (include "rbt-data-generator.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Name of the shared (non-secret) env ConfigMap.
*/}}
{{- define "rbt-data-generator.envConfigMapName" -}}
{{- printf "%s-env" (include "rbt-data-generator.fullname" .) }}
{{- end }}

{{/*
Name of the in-chart Postgres Service.
*/}}
{{- define "rbt-data-generator.postgresServiceName" -}}
{{- printf "%s-postgres" (include "rbt-data-generator.fullname" .) }}
{{- end }}

{{/*
Database host workloads connect to: the in-chart Service, or an external host.
*/}}
{{- define "rbt-data-generator.postgresHost" -}}
{{- if .Values.postgres.enabled }}
{{- include "rbt-data-generator.postgresServiceName" . }}
{{- else }}
{{- required "postgres.enabled is false: set postgres.external.host" .Values.postgres.external.host }}
{{- end }}
{{- end }}

{{/*
Database port workloads connect to.
*/}}
{{- define "rbt-data-generator.postgresPort" -}}
{{- if .Values.postgres.enabled }}
{{- .Values.postgres.service.port }}
{{- else }}
{{- .Values.postgres.external.port }}
{{- end }}
{{- end }}

{{/*
envFrom block shared by every rbt workload: non-secret config + DB secret.
*/}}
{{- define "rbt-data-generator.rbtEnvFrom" -}}
- configMapRef:
    name: {{ include "rbt-data-generator.envConfigMapName" . }}
- secretRef:
    name: {{ include "rbt-data-generator.secretName" . }}
{{- end }}

{{/*
initContainer that blocks until Postgres accepts connections, replacing the
compose depends_on: service_healthy gate. Uses pg_isready, present in the image.
*/}}
{{- define "rbt-data-generator.waitForPostgres" -}}
- name: wait-for-postgres
  image: {{ include "rbt-data-generator.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - |
      until pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USR" -d "$PG_DATABASE"; do
        echo "waiting for postgres at $PG_HOST:$PG_PORT ..."
        sleep 3
      done
  envFrom:
    {{- include "rbt-data-generator.rbtEnvFrom" . | nindent 4 }}
{{- end }}

{{/*
Claim name for the shared output volume.
*/}}
{{- define "rbt-data-generator.outputClaimName" -}}
{{- default (printf "%s-output" (include "rbt-data-generator.fullname" .)) .Values.output.persistence.existingClaim }}
{{- end }}

{{/*
Claim name for the setup cache volume.
*/}}
{{- define "rbt-data-generator.setupCacheClaimName" -}}
{{- default (printf "%s-setup-cache" (include "rbt-data-generator.fullname" .)) .Values.cache.setup.existingClaim }}
{{- end }}

{{/*
Claim name for the osm cache volume.
*/}}
{{- define "rbt-data-generator.osmCacheClaimName" -}}
{{- default (printf "%s-osm-cache" (include "rbt-data-generator.fullname" .)) .Values.cache.osm.existingClaim }}
{{- end }}

{{/*
imagePullSecrets block.
*/}}
{{- define "rbt-data-generator.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
