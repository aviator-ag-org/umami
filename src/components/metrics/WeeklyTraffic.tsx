import { Focusable, Grid, Row, Text, Tooltip, TooltipTrigger } from '@umami/react-zen';
import { addHours, format, startOfDay } from 'date-fns';
import { Fragment } from 'react';
import { LoadingPanel } from '@/components/common/LoadingPanel';
import { useLocale, useMessages, useWeeklyTrafficQuery } from '@/components/hooks';
import { getDayOfWeekAsDate } from '@/lib/date';

const HOURS = Array.from({ length: 24 }, (_, i) => i);
const LEGEND_STEPS = [0, 0.25, 0.5, 0.75, 1];

function getCellColor(pct: number) {
  return pct > 0
    ? `color-mix(in oklch, var(--primary) ${Math.round(15 + pct * 85)}%, var(--surface-raised))`
    : 'var(--surface-raised)';
}

export function WeeklyTraffic({ websiteId }: { websiteId: string }) {
  const { data, isLoading, error } = useWeeklyTrafficQuery(websiteId);
  const { dateLocale } = useLocale();
  const { labels, t } = useMessages();
  const { weekStartsOn } = dateLocale.options;
  const daysOfWeek = Array(7)
    .fill(weekStartsOn)
    .map((d, i) => (d + i) % 7);

  const formatDay = (day: number, pattern: string) =>
    format(getDayOfWeekAsDate(day), pattern, { locale: dateLocale });
  const formatHour = (hour: number) =>
    format(addHours(startOfDay(new Date()), hour), 'haaa', { locale: dateLocale });

  const peak = data
    ? daysOfWeek.reduce(
        (best, day) => {
          data[day]?.forEach((count: number, hour: number) => {
            if (count > best.count) {
              best = { day, hour, count };
            }
          });
          return best;
        },
        { day: 0, hour: 0, count: 0 },
      )
    : null;

  const max = peak?.count || 1;

  return (
    <LoadingPanel data={data} isLoading={isLoading} error={error}>
      {data && (
        <>
          <Row justifyContent="space-between" alignItems="center" wrap="wrap" gap marginBottom="4">
            {peak?.count > 0 && (
              <Row alignItems="center" gap="2">
                <Text color="muted">{t(labels.peak)}</Text>
                <Text weight="bold">
                  {`${formatDay(peak.day, 'EEEE')} ${formatHour(peak.hour)}`}
                </Text>
                <Text color="muted">{`· ${peak.count} ${t(labels.visitors).toLowerCase()}`}</Text>
              </Row>
            )}
            <Row alignItems="center" gap="2">
              <Text size="sm" color="muted">
                {t(labels.less)}
              </Text>
              {LEGEND_STEPS.map(step => (
                <div
                  key={step}
                  style={{
                    width: 14,
                    height: 14,
                    borderRadius: 3,
                    backgroundColor: getCellColor(step),
                  }}
                />
              ))}
              <Text size="sm" color="muted">
                {t(labels.more)}
              </Text>
            </Row>
          </Row>
          <Grid columns="auto repeat(24, minmax(0, 1fr))" gap="1" alignItems="center">
            <Row />
            {HOURS.map(hour => (
              <Row key={hour} justifyContent="center">
                {hour % 3 === 0 && (
                  <Text size="xs" color="muted" wrap="nowrap">
                    {formatHour(hour)}
                  </Text>
                )}
              </Row>
            ))}
            {daysOfWeek.map(day => (
              <Fragment key={day}>
                <Row paddingRight="2">
                  <Text size="sm" weight="bold">
                    {formatDay(day, 'EEE')}
                  </Text>
                </Row>
                {HOURS.map(hour => {
                  const count = data[day]?.[hour] || 0;
                  return (
                    <TooltipTrigger key={`${day}-${hour}`} delay={0}>
                      <Focusable>
                        <div
                          role="button"
                          style={{
                            aspectRatio: '1',
                            minHeight: 12,
                            borderRadius: 4,
                            backgroundColor: getCellColor(count / max),
                          }}
                        />
                      </Focusable>
                      <Tooltip
                        placement="top"
                        style={{ backgroundColor: 'rgba(0,0,0,0.8)', color: 'white' }}
                      >
                        <Text size="base">
                          {`${formatDay(day, 'EEEE')} ${formatHour(hour)} · ${t(labels.visitors)}: ${count}`}
                        </Text>
                      </Tooltip>
                    </TooltipTrigger>
                  );
                })}
              </Fragment>
            ))}
          </Grid>
        </>
      )}
    </LoadingPanel>
  );
}
