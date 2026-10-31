import { render, screen } from '@testing-library/react';
import { pairLabel, PLATE_STATUSES } from './eligibility';
import { MapMarker } from './MapMarker';
import { EligibilityPair, PlateStack } from './PlateStack';

describe('PlateStack', () => {
  it.each([
    ['scooter', 'allowed', '普通機車可停'],
    ['heavy', 'conditional', '大型重機有條件可停'],
    ['heavy', 'denied', '大型重機不可停'],
    ['scooter', 'notStated', '普通機車官方未標示'],
    ['heavy', 'legacyUnknown', '大型重機待確認（舊資料）'],
  ] as const)('%s %s is named %s', (vehicle, status, label) => {
    render(<PlateStack vehicle={vehicle} status={status} />);
    expect(screen.getByRole('img', { name: label })).toHaveAttribute('data-status', status);
  });

  it('draws each status with its own class, so no two look alike', () => {
    const { container } = render(
      <>
        {PLATE_STATUSES.map((status) => (
          <PlateStack key={status} vehicle="heavy" status={status} />
        ))}
      </>,
    );
    const classes = [...container.querySelectorAll('.plate-stack')].map((el) => el.className);
    expect(new Set(classes).size).toBe(PLATE_STATUSES.length);
  });

  it('accepts a contextual label for 目前 → 建議', () => {
    render(<PlateStack vehicle="heavy" status="allowed" size="large" label="建議改為可停" />);
    expect(screen.getByRole('img', { name: '建議改為可停' })).toHaveClass('plate-stack--large');
  });
});

describe('EligibilityPair', () => {
  it('reads both vehicles in fixed order: 普通機車 then 大型重機', () => {
    render(<EligibilityPair scooter="allowed" heavy="denied" />);
    expect(screen.getByRole('img', { name: '普通機車可停，大型重機不可停' })).toBeInTheDocument();
    expect(pairLabel('notStated', 'conditional')).toBe('普通機車官方未標示，大型重機有條件可停');
  });
});

describe('MapMarker', () => {
  it('names the state and the shared-bay badge', () => {
    render(<MapMarker state="conditional" shared name="復興南路一段 107 巷" />);
    expect(screen.getByRole('img', { name: '復興南路一段 107 巷，有條件，普大共用格' })).toHaveAttribute(
      'data-state',
      'conditional',
    );
  });

  it('shows P only for 可停', () => {
    const { container, rerender } = render(<MapMarker state="allowed" />);
    expect(container.textContent).toBe('P');
    rerender(<MapMarker state="denied" />);
    expect(container.textContent).toBe('');
    expect(container.querySelector('svg path')).not.toBeNull();
  });
});
