'use client';
import { Column, Heading, Row } from '@umami/react-zen';
import { ExpandedViewModal } from '@/app/(main)/websites/[websiteId]/ExpandedViewModal';
import { Panel } from '@/components/common/Panel';
import { useMessages } from '@/components/hooks';
import { UnitFilter } from '@/components/input/UnitFilter';
import { WeeklyTraffic } from '@/components/metrics/WeeklyTraffic';
import { WebsiteChart } from './WebsiteChart';
import { WebsiteControls } from './WebsiteControls';
import { WebsiteMetricsBar } from './WebsiteMetricsBar';
import { WebsitePanels } from './WebsitePanels';

export function WebsitePage({ websiteId }: { websiteId: string }) {
  const { t, labels } = useMessages();

  return (
    <Column gap>
      <WebsiteControls websiteId={websiteId} allowBounceFilter={true} />
      <WebsiteMetricsBar websiteId={websiteId} showChange={true} />
      <Panel minHeight="520px">
        <Row justifyContent="end">
          <UnitFilter />
        </Row>
        <WebsiteChart websiteId={websiteId} />
      </Panel>
      <Panel data-test="traffic-heatmap">
        <Heading size="2xl">{t(labels.traffic)}</Heading>
        <WeeklyTraffic websiteId={websiteId} />
      </Panel>
      <WebsitePanels websiteId={websiteId} />
      <ExpandedViewModal websiteId={websiteId} />
    </Column>
  );
}
