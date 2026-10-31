import { createContext, useContext } from 'react';

/**
 * Which data the admin is showing: none yet (production until admin_v1,
 * #195), the in-memory fixture (`--mode fixture`, tests), or live data.
 */
export type DataConnection = 'none' | 'fixture' | 'live';

export const DataConnectionContext = createContext<DataConnection>('none');

export const useDataConnection = () => useContext(DataConnectionContext);
